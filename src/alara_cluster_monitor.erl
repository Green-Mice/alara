%% ============================================================================
%% alara_cluster_monitor - Remote Node Tracker (skeleton)
%%
%% Full ETS/reconnect implementation follows in Task 2.
%% ============================================================================

-module(alara_cluster_monitor).
-behaviour(gen_server).

-export([start_link/0, get_reachable_nodes/0, get_all_nodes/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_reachable_nodes() -> [node()].
get_reachable_nodes() -> [].

-spec get_all_nodes() -> [{node(), up | down}].
get_all_nodes() -> [].

init([])                 -> {ok, #{}}.
handle_call(_, _, State) -> {reply, ok, State}.
handle_cast(_, State)    -> {noreply, State}.
handle_info(_, State)    -> {noreply, State}.
terminate(_, _)          -> ok.
code_change(_, State, _) -> {ok, State}.
