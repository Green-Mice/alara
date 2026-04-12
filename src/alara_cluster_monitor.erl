%% ============================================================================
%% alara_cluster_monitor - Remote Node Tracker
%%
%% Maintains a live ETS view of which configured remote alara nodes are
%% currently reachable. Uses erlang:monitor_node/2 for instant notifications
%% and a periodic reconnect timer for nodes that were down at startup.
%%
%% ETS table: alara_cluster_nodes — {node(), up | down}
%% Access: public — read by collect_entropy without a message hop.
%%
%% Configuration
%% -------------
%%   {alara, [{remote_nodes, ['node1@host', 'node2@host']}]}
%%
%% The reconnect interval is fixed at 10 s (YAGNI — not configurable yet).
%% ============================================================================

-module(alara_cluster_monitor).
-behaviour(gen_server).

-export([start_link/0, get_reachable_nodes/0, get_all_nodes/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS, alara_cluster_nodes).
-define(RECONNECT_MS, 10000).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Return all configured remote nodes currently reachable.
%% Returns [] if the ETS table does not exist (monitor restarting).
-spec get_reachable_nodes() -> [node()].
get_reachable_nodes() ->
    try
        ets:select(?ETS, [{{'$1', up}, [], ['$1']}])
    catch
        error:badarg -> []
    end.

%% @doc Return all configured remote nodes with their current status.
%% Returns [] if the ETS table does not exist (monitor restarting).
-spec get_all_nodes() -> [{node(), up | down}].
get_all_nodes() ->
    try
        ets:tab2list(?ETS)
    catch
        error:badarg -> []
    end.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

init([]) ->
    ?ETS = ets:new(?ETS, [named_table, public, set]),
    RemoteNodes = application:get_env(alara, remote_nodes, []),
    lists:foreach(fun(Node) ->
        Status = try_connect(Node),
        ets:insert(?ETS, {Node, Status})
    end, RemoteNodes),
    schedule_reconnect(),
    {ok, #{configured => RemoteNodes}}.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Only update ETS for nodes we actually configured.
handle_info({nodeup, Node}, State) ->
    case ets:member(?ETS, Node) of
        true ->
            ets:insert(?ETS, {Node, up}),
            erlang:monitor_node(Node, true);
        false ->
            ok
    end,
    {noreply, State};

handle_info({nodedown, Node}, State) ->
    case ets:member(?ETS, Node) of
        true  -> ets:insert(?ETS, {Node, down});
        false -> ok
    end,
    {noreply, State};

handle_info(reconnect_tick, State) ->
    DownNodes = ets:select(?ETS, [{{'$1', down}, [], ['$1']}]),
    lists:foreach(fun(Node) ->
        case try_connect(Node) of
            up ->
                ets:insert(?ETS, {Node, up}),
                erlang:monitor_node(Node, true);
            down ->
                ok
        end
    end, DownNodes),
    schedule_reconnect(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

try_connect(Node) ->
    case net_kernel:connect_node(Node) of
        true    -> up;
        false   -> down;
        ignored -> down
    end.

schedule_reconnect() ->
    erlang:send_after(?RECONNECT_MS, self(), reconnect_tick).
