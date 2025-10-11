%% ============================================================================
%% ALARA - Distributed Entropy Network System
%% Complete Erlang Implementation based on Coq Formalization
%% ============================================================================

-module(alara).
-behaviour(gen_server).
-include_lib("alara/include/alara.hrl").

%% API
-export([
    start_link/1,
    create_network/0,
    create_network/1,
    add_connection/3,
    remove_connection/3,
    get_network_quality/1,
    get_network_state/1,
    get_nodes/1,
    generate_random_bools/1,
    generate_random_bools/2,
    generate_random_int/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ============================================================================
%% API FUNCTIONS
%% ============================================================================

%% Create a network with 3 nodes
create_network() ->
    gen_server:start_link(?MODULE, [3], []).
%% Create a network with N nodes
create_network(NumNodes) ->
    gen_server:start_link(?MODULE, [NumNodes], []).

start_link(NumNodes) ->
    gen_server:start_link(?MODULE, [NumNodes], []).

%% Add a connection between two nodes
add_connection(NetworkPid, NodePid1, NodePid2) ->
    gen_server:call(NetworkPid, {add_connection, NodePid1, NodePid2}).

%% Remove a connection between two nodes
remove_connection(NetworkPid, NodePid1, NodePid2) ->
    gen_server:call(NetworkPid, {remove_connection, NodePid1, NodePid2}).

%% Get the network quality metric
get_network_quality(NetworkPid) ->
    gen_server:call(NetworkPid, get_network_quality).

%% Get the current network state
get_network_state(NetworkPid) ->
    gen_server:call(NetworkPid, get_network_state).

%% Get all node PIDs in the network
get_nodes(NetworkPid) ->
    gen_server:call(NetworkPid, get_nodes).

%% Generate N random booleans distributed across all nodes in the supervisor
generate_random_bools(N) when is_integer(N), N > 0 ->
    alara_node_sup:generate_random_bools(N).

%% Generate N random booleans from a specific node
generate_random_bools(NodePid, N) when is_integer(N), N > 0 ->
    [alara_node:get_random(NodePid) || _ <- lists:seq(1, N)].

%% Generate a random integer using NBits distributed across all nodes in the supervisor
generate_random_int(NBits) when is_integer(NBits), NBits > 0 ->
    alara_node_sup:generate_random_int(NBits).

%% ============================================================================
%% GEN_SERVER CALLBACKS
%% ============================================================================

init([NumNodes]) when is_integer(NumNodes), NumNodes > 0 ->
    process_flag(trap_exit, true),
    %% Start the node supervisor - it automatically starts all nodes
    SupPid = case alara_node_sup:start_link(NumNodes) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end,
    
    %% Get the node PIDs that were just started
    NodePids = alara_node_sup:get_nodes(),

    State = #state{
        network = #distributed_entropy_network{
            nodes = NodePids,
            topology = [],
            global_entropy_pool = [],
            consensus_round = 0,
            network_quality = 0.0
        },
        node_processes = SupPid,
        consensus_timer = undefined
    },
    {ok, State}.

handle_call({add_connection, NodePid1, NodePid2}, _From, State) ->
    #state{network = Network} = State,
    Nodes = Network#distributed_entropy_network.nodes,
    case lists:member(NodePid1, Nodes) andalso lists:member(NodePid2, Nodes) of
        true ->
            NewTopology = [{NodePid1, NodePid2}, {NodePid2, NodePid1} |
                         Network#distributed_entropy_network.topology],
            UpdatedNetwork = Network#distributed_entropy_network{
                topology = lists:usort(NewTopology)
            },
            NewState = State#state{network = UpdatedNetwork},
            {reply, {ok, nodes_connected}, NewState};
        false ->
            {reply, {error, node_not_found}, State}
    end;

handle_call({remove_connection, NodePid1, NodePid2}, _From, State) ->
    #state{network = Network} = State,
    UpdatedTopology = lists:filter(
        fun({N1, N2}) -> 
            not ((N1 =:= NodePid1 andalso N2 =:= NodePid2) orelse
                 (N1 =:= NodePid2 andalso N2 =:= NodePid1))
        end,
        Network#distributed_entropy_network.topology
    ),
    UpdatedNetwork = Network#distributed_entropy_network{
        topology = UpdatedTopology
    },
    NewState = State#state{network = UpdatedNetwork},
    {reply, {ok, connection_removed}, NewState};

handle_call(get_network_quality, _From, State) ->
    #state{network = Network} = State,
    %% Calculate quality based on number of active nodes and connections
    NumNodes = length(Network#distributed_entropy_network.nodes),
    NumConnections = length(Network#distributed_entropy_network.topology) div 2,
    Quality = case NumNodes of
        0 -> 0.0;
        1 -> 0.0;
        N -> NumConnections / (N * (N - 1) / 2)
    end,
    UpdatedNetwork = Network#distributed_entropy_network{
        network_quality = Quality
    },
    NewState = State#state{network = UpdatedNetwork},
    {reply, {ok, Quality}, NewState};

handle_call(get_network_state, _From, State) ->
    {reply, {ok, State#state.network}, State};

handle_call(get_nodes, _From, State) ->
    Nodes = State#state.network#distributed_entropy_network.nodes,
    {reply, {ok, Nodes}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State) ->
    io:format("Process ~p exited with reason: ~p~n", [Pid, Reason]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ============================================================================
%% INTERNAL FUNCTIONS
%% ============================================================================
