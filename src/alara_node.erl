%% ============================================================================
%% alara_node - Single Entropy Worker
%%
%% Each node is a lightweight gen_server whose only job is to produce
%% cryptographically secure random bytes via `crypto:strong_rand_bytes/1`.
%%
%% Design decisions
%% ----------------
%% - `crypto:strong_rand_bytes/1` is used exclusively (never `rand`).
%%   The `rand` module is explicitly documented as unsuitable for
%%   cryptographic use (see OTP stdlib docs).
%% - The worker holds NO mutable state: randomness is produced on every
%%   call, so there is nothing to compromise at rest.
%% - The public API operates on *bytes*, not individual bits, to keep
%%   the number of inter-process messages proportional to the amount of
%%   data requested rather than to every single bit.
%% ============================================================================

-module(alara_node).
-behaviour(gen_server).

-include_lib("alara/include/alara.hrl").

%% Public API
-export([start_link/0, get_random_bytes/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

%% @doc Start a new entropy worker and link it to the calling process.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% @doc Request `N` cryptographically secure random bytes from `NodePid`.
%%
%% A single synchronous call is used so that the supervisor's health
%% monitoring stays accurate: a slow/dead node will surface as a timeout
%% rather than a silent hang.
-spec get_random_bytes(NodePid :: pid(), N :: pos_integer()) -> binary().
get_random_bytes(NodePid, N) when is_pid(NodePid), is_integer(N), N > 0 ->
    gen_server:call(NodePid, {get_random_bytes, N}).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

init([]) ->
    {ok, #node_state{}}.

handle_call({get_random_bytes, N}, _From, State) ->
    %% crypto:strong_rand_bytes/1 is the only OTP function suitable for
    %% generating data that will feed cryptographic operations.
    Bytes = crypto:strong_rand_bytes(N),
    {reply, Bytes, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
