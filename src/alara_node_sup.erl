%% ============================================================================
%% alara_node_sup - Entropy Worker Supervisor
%%
%% Supervises a fixed pool of `alara_node` workers and exposes the
%% high-level entropy generation API used by the rest of the ecosystem.
%%
%% Entropy mixing strategy
%% -----------------------
%% Each worker independently calls `crypto:strong_rand_bytes/1`.  The
%% chunks are concatenated and passed through HKDF (RFC 5869) using
%% SHA3-256 as the underlying PRF.  This construction has two important
%% properties regardless of the requested output size:
%%
%%   1. **Security**: even if all but one worker is fully compromised and
%%      returns attacker-controlled bytes, the output remains
%%      unpredictable to that attacker (as long as one honest node
%%      contributes genuine randomness).
%%
%%   2. **Uniformity**: HKDF smooths any statistical bias that might
%%      appear in a single node's output and produces arbitrarily long
%%      output without truncation or padding artefacts.
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
    LocalWorkers = get_nodes(),
    case collect_entropy(LocalWorkers, N) of
        {ok, Raw}        -> mix_entropy(Raw, N);
        {error, _} = Err -> Err
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

%% Distribute the byte request across all available sources:
%% local worker PIDs (always) + reachable remote alara nodes (when configured).
%%
%% For local PIDs : call alara_node:get_random_bytes directly.
%% For remote nodes: rpc:call → alara:generate_random_bytes on the remote node.
%%   {badrpc, _} → lambda sends 'skip', collect_chunks silently drops it.
%%
%% Two-level HKDF: each remote node HKDF-mixes its own local pool before
%% replying; the coordinator then HKDF-mixes all contributions together.
-spec collect_entropy([pid()], pos_integer()) ->
    {ok, binary()} | {error, no_nodes | {worker_died, term()}}.
collect_entropy(LocalWorkers, TotalBytes) ->
    RemoteNodes = alara_cluster_monitor:get_reachable_nodes(),
    AllSources  = LocalWorkers ++ RemoteNodes,
    case AllSources of
        [] ->
            {error, no_nodes};
        _ ->
            Timeout    = application:get_env(alara, remote_timeout_ms, 5000),
            NumSources = length(AllSources),
            BytesPer   = TotalBytes div NumSources,
            Remainder  = TotalBytes rem NumSources,
            Self       = self(),
            Pending = [begin
                           Ref = make_ref(),
                           Share = case {I, Remainder} of
                               {1, R} when R > 0 -> BytesPer + R;
                               _                 -> BytesPer
                           end,
                           {_, MRef} = spawn_monitor(fun() ->
                               Msg = fetch_chunk(Source, max(1, Share), Timeout),
                               Self ! {Ref, Msg}
                           end),
                           {Ref, MRef}
                       end || {I, Source} <-
                               lists:zip(lists:seq(1, NumSources), AllSources)],
            collect_chunks(Pending, [])
    end.

%% Fetch bytes from a local PID worker or a remote node.
%% Remote failures return the atom 'skip' (never crash the lambda).
-spec fetch_chunk(pid() | node(), pos_integer(), pos_integer()) ->
    binary() | skip.
fetch_chunk(Source, N, _Timeout) when is_pid(Source) ->
    alara_node:get_random_bytes(Source, N);
fetch_chunk(Source, N, Timeout) when is_atom(Source) ->
    case rpc:call(Source, alara, generate_random_bytes, [N], Timeout) of
        {badrpc, _} -> skip;
        Bytes       -> Bytes
    end.

%% Collect lambda results in order.
%% skip  : remote node was unreachable — silently drop, continue.
%% DOWN  : local worker crashed — cancel remaining monitors, return error.
-spec collect_chunks([{reference(), reference()}], [binary()]) ->
    {ok, binary()} | {error, no_nodes | {worker_died, term()}}.
collect_chunks([], []) ->
    {error, no_nodes};
collect_chunks([], Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
collect_chunks([{Ref, MRef} | Rest], Acc) ->
    receive
        {Ref, skip} ->
            demonitor(MRef, [flush]),
            collect_chunks(Rest, Acc);
        {Ref, Chunk} ->
            demonitor(MRef, [flush]),
            collect_chunks(Rest, [Chunk | Acc]);
        {'DOWN', MRef, process, _Pid, Reason} ->
            [demonitor(M, [flush]) || {_, M} <- Rest],
            {error, {worker_died, Reason}}
    end.

%% Mix all worker contributions via HKDF (RFC 5869).
%%
%% HKDF-Extract derives a pseudorandom key (PRK) from the concatenated
%% worker bytes; HKDF-Expand then stretches it to exactly RequestedBytes.
%%
%% This construction preserves the security guarantee for ANY output size:
%% even if all workers but one are fully compromised and return attacker-
%% controlled bytes, the output remains unpredictable to that attacker as
%% long as one honest worker contributes genuine randomness.
-spec mix_entropy(Raw :: binary(), RequestedBytes :: pos_integer()) -> binary().
mix_entropy(Raw, RequestedBytes) ->
    %% Extract: PRK = HMAC-SHA3-256(salt=<<>>, IKM=Raw)
    PRK = crypto:mac(hmac, ?MIX_HASH, <<>>, Raw),
    %% Expand: derive exactly RequestedBytes from PRK
    hkdf_expand(?MIX_HASH, PRK, <<>>, RequestedBytes).

%% HKDF-Expand (RFC 5869 §2.3).
%% Produces L bytes by iterating HMAC-Hash:
%%   T(1) = HMAC(PRK, ""      || info || 0x01)
%%   T(i) = HMAC(PRK, T(i-1) || info || 0xi)
%%   OKM  = first L bytes of T(1) || T(2) || ...
-spec hkdf_expand(atom(), binary(), binary(), pos_integer()) -> binary().
hkdf_expand(Hash, PRK, Info, L) ->
    hkdf_expand_loop(Hash, PRK, Info, L, 1, <<>>, <<>>).

hkdf_expand_loop(_Hash, _PRK, _Info, L, _I, _TPrev, Acc)
        when byte_size(Acc) >= L ->
    binary:part(Acc, 0, L);
hkdf_expand_loop(Hash, PRK, Info, L, I, TPrev, Acc) ->
    T = crypto:mac(hmac, Hash, PRK, <<TPrev/binary, Info/binary, I:8>>),
    hkdf_expand_loop(Hash, PRK, Info, L, I + 1, T, <<Acc/binary, T/binary>>).


