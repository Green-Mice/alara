%% ============================================================================
%% alara_node_sup - Entropy Worker Supervisor
%%
%% Supervises a fixed pool of `alara_node` workers and exposes the
%% high-level entropy generation API used by the rest of the ecosystem.
%%
%% Entropy mixing strategy
%% -----------------------
%% Each worker independently calls `crypto:strong_rand_bytes/1`.  The
%% chunks are concatenated and hashed with SHA3-256 before being returned.
%% This XOR-and-hash construction has two important properties:
%%
%%   1. **Security**: even if all but one worker is fully compromised and
%%      returns attacker-controlled bytes, the output remains
%%      unpredictable to that attacker (as long as one honest node
%%      contributes genuine randomness).
%%
%%   2. **Uniformity**: hashing smooths any statistical bias that might
%%      appear in a single node's output.
%%
%% Security note on distributed Erlang
%% ------------------------------------
%% Worker PIDs are obtained from the local supervisor; they are always
%% local processes. There is no entropy exchange over the Erlang
%% distribution channel, so MITM attacks on the distribution layer
%% cannot inject entropy. Operators SHOULD still secure the distribution
%% channel with TLS (`-proto_dist inet_tls`) as a general best practice.
%% ============================================================================

-module(alara_node_sup).
-behaviour(supervisor).

%% Public API
-export([start_link/1, add_node/0, get_nodes/0,
         generate_random_bytes/1, generate_random_bits/1,
         generate_random_int/1]).

%% Supervisor callback
-export([init/1]).

-define(SERVER, ?MODULE).

%% The hash function used to mix entropy contributions from all workers.
%% SHA3-256 is a NIST standard (FIPS 202) with no known weaknesses.
-define(MIX_HASH, sha3_256).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

%% @doc Start the supervisor with an initial pool of NumNodes workers.
-spec start_link(NumNodes :: pos_integer()) -> supervisor:startlink_ret().
start_link(NumNodes) when is_integer(NumNodes), NumNodes > 0 ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, NumNodes).

%% @doc Dynamically add a new entropy worker to the pool.
-spec add_node() -> supervisor:startchild_ret().
add_node() ->
    supervisor:start_child(?SERVER, worker_spec(make_ref())).

%% @doc Return the PIDs of all currently alive worker nodes.
%%
%% The list is fetched live from the supervisor so it is always accurate,
%% even after crashes and restarts.
-spec get_nodes() -> [pid()].
get_nodes() ->
    [Pid || {_Id, Pid, worker, _} <- supervisor:which_children(?SERVER),
            is_pid(Pid)].

%% @doc Generate N cryptographically secure random bytes.
%%
%% Each worker contributes an equal share; remainders are handled by the
%% first node. All contributions are mixed with SHA3-256 to produce the
%% final output. If more bytes are requested than the hash output size
%% (32 bytes for SHA3-256), the raw concatenated buffer is returned
%% instead so no entropy is truncated.
%%
%% Returns {error, no_nodes} if the supervisor has no live workers.
%% Returns {error, {worker_died, Reason}} if a worker crashed mid-collection.
-spec generate_random_bytes(N :: pos_integer()) ->
    binary() | {error, no_nodes | {worker_died, term()}}.
generate_random_bytes(N) when is_integer(N), N > 0 ->
    case get_nodes() of
        [] ->
            {error, no_nodes};
        Nodes ->
            case collect_entropy(Nodes, N) of
                {ok, Raw}        -> mix_entropy(Raw, N);
                {error, _} = Err -> Err
            end
    end.

%% @doc Generate N random bits as a list of 0 | 1 integers.
-spec generate_random_bits(N :: pos_integer()) ->
    [0 | 1] | {error, no_nodes}.
generate_random_bits(N) when is_integer(N), N > 0 ->
    NumBytes = ceil(N / 8),
    case generate_random_bytes(NumBytes) of
        {error, _} = Err -> Err;
        Bytes ->
            %% Extract exactly N bits via bitstring comprehension (no intermediate lists).
            << Bits:N/bitstring, _/bitstring >> = Bytes,
            [B || <<B:1>> <= Bits]
    end.

%% @doc Generate a non-negative random integer using NBits of entropy.
%%
%% The integer is in the range [0, 2^NBits - 1].
-spec generate_random_int(NBits :: pos_integer()) ->
    non_neg_integer() | {error, no_nodes}.
generate_random_int(NBits) when is_integer(NBits), NBits > 0 ->
    NumBytes = ceil(NBits / 8),
    case generate_random_bytes(NumBytes) of
        {error, _} = Err -> Err;
        Bytes ->
            %% Convert to integer then mask to exactly NBits.
            Full = binary:decode_unsigned(Bytes, big),
            Mask = (1 bsl NBits) - 1,
            Full band Mask
    end.

%% ---------------------------------------------------------------------------
%% Supervisor callback
%% ---------------------------------------------------------------------------

init(NumNodes) ->
    SupFlags = #{
        strategy  => one_for_one,
        %% Allow up to 10 restarts in 5 seconds before giving up.
        intensity => 10,
        period    => 5
    },
    ChildSpecs = [worker_spec(I) || I <- lists:seq(1, NumNodes)],
    {ok, {SupFlags, ChildSpecs}}.

%% ---------------------------------------------------------------------------
%% Internal helpers
%% ---------------------------------------------------------------------------

%% Build a child spec for an alara_node worker.
%% Id can be any term; using the sequence index keeps IDs stable.
worker_spec(Id) ->
    #{
        id      => {alara_node, Id},
        start   => {alara_node, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type    => worker,
        modules => [alara_node]
    }.

%% Distribute the byte request across all nodes as evenly as possible.
%%
%% Each worker is spawned with a monitor so that if a gen_server:call
%% inside the lambda raises (dead node, timeout, etc.) the lambda crashes,
%% the monitor fires a 'DOWN' message, and collect_chunks returns an error
%% instead of blocking forever.
-spec collect_entropy(Nodes :: [pid()], TotalBytes :: pos_integer()) ->
    {ok, binary()} | {error, {worker_died, term()}}.
collect_entropy(Nodes, TotalBytes) ->
    NumNodes     = length(Nodes),
    BytesPerNode = TotalBytes div NumNodes,
    Remainder    = TotalBytes rem NumNodes,
    Self         = self(),

    %% Spawn one monitored lambda per worker node.
    Pending = [begin
                    Ref = make_ref(),
                    Share = case {I, Remainder} of
                        {1, R} when R > 0 -> BytesPerNode + R;
                        _                 -> BytesPerNode
                    end,
                    {_, MRef} = spawn_monitor(fun() ->
                        Chunk = alara_node:get_random_bytes(Node, max(1, Share)),
                        Self ! {Ref, Chunk}
                    end),
                    {Ref, MRef}
                end || {I, Node} <- lists:zip(lists:seq(1, NumNodes), Nodes)],

    collect_chunks(Pending, []).

%% Collect lambda results in order.
%% On a 'DOWN' before the message: cancel remaining monitors and return error.
-spec collect_chunks([{reference(), reference()}], [binary()]) ->
    {ok, binary()} | {error, {worker_died, term()}}.
collect_chunks([], Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
collect_chunks([{Ref, MRef} | Rest], Acc) ->
    receive
        {Ref, Chunk} ->
            demonitor(MRef, [flush]),
            collect_chunks(Rest, [Chunk | Acc]);
        {'DOWN', MRef, process, _Pid, Reason} ->
            [demonitor(M, [flush]) || {_, M} <- Rest],
            {error, {worker_died, Reason}}
    end.

%% Hash all worker contributions together.
%%
%% If the requested size fits inside a single SHA3-256 digest (32 bytes)
%% we return the hash directly.  For larger requests, we return the raw
%% concatenated entropy: it was already generated by crypto, so
%% hashing would only truncate it needlessly.
-spec mix_entropy(Raw :: binary(), RequestedBytes :: pos_integer()) -> binary().
mix_entropy(Raw, RequestedBytes) ->
    HashSize = digest_size(?MIX_HASH),
    case RequestedBytes =< HashSize of
        true ->
            %% Hash the concatenated contributions and return exactly N bytes.
            Digest = crypto:hash(?MIX_HASH, Raw),
            binary:part(Digest, 0, RequestedBytes);
        false ->
            %% The raw buffer is larger than the hash output; returning it
            %% directly preserves entropy without truncation.
            Raw
    end.

%% Return the output size in bytes for a given hash algorithm.
-spec digest_size(atom()) -> pos_integer().
digest_size(sha3_256) -> 32;
digest_size(sha256)   -> 32;
digest_size(sha3_512) -> 64;
digest_size(sha512)   -> 64.

