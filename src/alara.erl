%% ============================================================================
%% alara - Distributed Entropy Network System
%%
%% ALARA is an OTP application that provides cryptographically secure
%% randomness by aggregating entropy from a supervised pool of worker
%% nodes. All output bytes pass through a SHA3-256 mixing step before
%% being returned to callers.
%%
%% Architecture
%% ------------
%%
%%   alara (gen_server, optional façade)
%%     └── alara_node_sup (supervisor)
%%           ├── alara_node  (entropy worker)
%%           ├── alara_node  (entropy worker)
%%           └── ...
%%
%% The `alara` gen_server is a thin façade that starts the supervisor and
%% re-exports the generation functions.  You can also call
%% `alara_node_sup` directly if you prefer a lighter call path.
%%
%% Security requirements
%% ---------------------
%% - Erlang distribution MUST be secured with TLS when running across
%%   physical or virtual machines (`-proto_dist inet_tls`).
%% - The Erlang cookie MUST be a high-entropy secret; do NOT use the
%%   default or any short value.
%% - This library has NOT been formally audited by an independent
%%   cryptographer.  Treat it as experimental for high-security
%%   production use until such an audit is completed.
%%
%% Quick start
%% -----------
%%
%%   {ok, Pid} = alara:create_network(5),
%%   Bytes     = alara:generate_random_bytes(32),
%%   Bits      = alara:generate_random_bits(256),
%%   Int       = alara:generate_random_int(128).
%%
%% ============================================================================

-module(alara).
-behaviour(gen_server).

-include_lib("alara/include/alara.hrl").

%% Public API
-export([
    create_network/0,
    create_network/1,
    start_link/1,
    get_nodes/1,
    generate_random_bytes/1,
    generate_random_bits/1,
    generate_random_int/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Default number of entropy workers when none is specified.
-define(DEFAULT_NODES, 3).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

%% @doc Start a network with the default number of entropy nodes (3).
-spec create_network() -> {ok, pid()} | {error, term()}.
create_network() ->
    create_network(?DEFAULT_NODES).

%% @doc Start a network with `NumNodes` entropy worker nodes.
%%
%% More nodes increase resilience to single-node failure and make the
%% combined entropy harder to predict, at the cost of slightly more
%% inter-process message overhead per request.
-spec create_network(NumNodes :: pos_integer()) -> {ok, pid()} | {error, term()}.
create_network(NumNodes) when is_integer(NumNodes), NumNodes > 0 ->
    gen_server:start_link(?MODULE, [NumNodes], []).

%% @doc OTP-compliant start with an explicit link.
-spec start_link(NumNodes :: pos_integer()) -> {ok, pid()} | {error, term()}.
start_link(NumNodes) ->
    gen_server:start_link(?MODULE, [NumNodes], []).

%% @doc Return the PIDs of all currently live entropy workers.
-spec get_nodes(NetworkPid :: pid()) -> {ok, [pid()]}.
get_nodes(NetworkPid) ->
    gen_server:call(NetworkPid, get_nodes).

%% ---------------------------------------------------------------------------
%% Entropy generation — these delegate to alara_node_sup directly so that
%% the call path does not add a redundant gen_server hop.
%% ---------------------------------------------------------------------------

%% @doc Generate `N` cryptographically secure random bytes.
%%
%% Entropy is collected from all workers in parallel and mixed with
%% SHA3-256 before being returned.  See `alara_node_sup` for the full
%% mixing strategy.
-spec generate_random_bytes(N :: pos_integer()) ->
    binary() | {error, no_nodes}.
generate_random_bytes(N) when is_integer(N), N > 0 ->
    alara_node_sup:generate_random_bytes(N).

%% @doc Generate `N` random bits as a list of `0 | 1` integers.
-spec generate_random_bits(N :: pos_integer()) ->
    [0 | 1] | {error, no_nodes}.
generate_random_bits(N) when is_integer(N), N > 0 ->
    alara_node_sup:generate_random_bits(N).

%% @doc Generate a non-negative random integer using `NBits` of entropy.
%%
%% The result is in the range `[0, 2^NBits - 1]`.
-spec generate_random_int(NBits :: pos_integer()) ->
    non_neg_integer() | {error, no_nodes}.
generate_random_int(NBits) when is_integer(NBits), NBits > 0 ->
    alara_node_sup:generate_random_int(NBits).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

init([NumNodes]) ->
    process_flag(trap_exit, true),
    SupPid = case alara_node_sup:start_link(NumNodes) of
        {ok, Pid}                      -> Pid;
        {error, {already_started, Pid}} -> Pid
    end,
    {ok, #state{node_supervisor = SupPid}}.

handle_call(get_nodes, _From, State) ->
    Nodes = alara_node_sup:get_nodes(),
    {reply, {ok, Nodes}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State) ->
    %% Log unexpected exits from linked processes (e.g. the supervisor).
    error_logger:warning_msg("alara: linked process ~p exited: ~p~n",
                             [Pid, Reason]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
