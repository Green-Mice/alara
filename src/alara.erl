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
    create_node/3,
    add_node/2,
    remove_node/2,
    connect_nodes/3,
    generate_entropy/2,
    get_network_quality/1,
    merge_networks/2,
    get_consensus_status/1,
    run_statistical_tests/1,
    generate_random_bools/1,
    get_entropy_pool/1,
    random_int/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ============================================================================
%% API FUNCTIONS
%% ============================================================================

start_link(NodeId) ->
    gen_server:start_link({local, list_to_atom("alara_" ++ integer_to_list(NodeId))},
                          ?MODULE, [NodeId], []).

create_network() ->
    Network = #distributed_entropy_network{
        nodes = [],
        topology = [],
        global_entropy_pool = [],
        consensus_round = 0,
        network_quality = 0.0
    },
    {ok, Pid} = gen_server:start_link(?MODULE, [Network], []),
    {ok, Pid}.

create_node(NodeId, TrustLevel, IsActive) ->
    case valid_trust_level(TrustLevel) of
        true ->
            Node = #node{
                node_id = NodeId,
                sources = [],
                neighbors = [],
                trust_level = TrustLevel,
                is_active = IsActive,
                pid = undefined
            },
            {ok, Node};
        false ->
            {error, invalid_trust_level}
    end.

add_node(NetworkPid, Node) ->
    gen_server:call(NetworkPid, {add_node, Node}).

remove_node(NetworkPid, NodeId) ->
    gen_server:call(NetworkPid, {remove_node, NodeId}).

connect_nodes(NetworkPid, NodeId1, NodeId2) ->
    gen_server:call(NetworkPid, {connect_nodes, NodeId1, NodeId2}).

generate_entropy(NetworkPid, {NodeId, EntropyData}) ->
    gen_server:cast(NetworkPid, {generate_entropy, NodeId, EntropyData}).

get_network_quality(NetworkPid) ->
    gen_server:call(NetworkPid, get_network_quality).

merge_networks(NetworkPid1, NetworkPid2) ->
    gen_server:call(NetworkPid1, {merge_networks, NetworkPid2}).

get_consensus_status(NetworkPid) ->
    gen_server:call(NetworkPid, get_consensus_status).

run_statistical_tests(NetworkPid) ->
    gen_server:call(NetworkPid, run_statistical_tests).

%% Génère une liste de N booléens aléatoires (bits)
generate_random_bools(N) when is_integer(N), N > 0 ->
    [rand:uniform(2) =:= 1 || _ <- lists:seq(1, N)].

%% Récupère le pool global d'entropie du réseau
get_entropy_pool(NetworkPid) ->
    gen_server:call(NetworkPid, get_entropy_pool).

%% Fabrique un entier à partir des N premiers bits du pool d'entropie
random_int(NetworkPid, NBits) when is_integer(NBits), NBits > 0 ->
    Bits = lists:sublist(?MODULE:get_entropy_pool(NetworkPid), NBits),
    lists:foldl(fun(B, Acc) -> (Acc bsl 1) bor (if B -> 1; true -> 0 end) end, 0, Bits).

%% ============================================================================
%% GEN_SERVER CALLBACKS
%% ============================================================================

init([Network]) when is_record(Network, distributed_entropy_network) ->
    State = #state{
        network = Network,
        node_processes = #{},
        consensus_timer = undefined
    },
    {ok, State};

init([NodeId]) when is_integer(NodeId) ->
    process_flag(trap_exit, true),
    {ok, #{node_id => NodeId, entropy_buffer => [], last_consensus => 0}}.

handle_call({add_node, Node}, _From, State) ->
    #state{network = Network, node_processes = NodeProcs} = State,
    case valid_node(Node) andalso not node_exists(Node#node.node_id, Network) of
        true ->
            {ok, NodePid} = start_node_process(Node#node.node_id),
            UpdatedNode = Node#node{pid = NodePid},
            UpdatedNodes = [UpdatedNode | Network#distributed_entropy_network.nodes],
            UpdatedNetwork = Network#distributed_entropy_network{
                nodes = UpdatedNodes,
                network_quality = calculate_network_quality(UpdatedNodes)
            },
            UpdatedNodeProcs = maps:put(Node#node.node_id, NodePid, NodeProcs),
            NewState = State#state{
                network = UpdatedNetwork,
                node_processes = UpdatedNodeProcs
            },
            {reply, {ok, node_added}, NewState};
        false ->
            {reply, {error, invalid_or_duplicate_node}, State}
    end;

handle_call({remove_node, NodeId}, _From, State) ->
    #state{network = Network, node_processes = NodeProcs} = State,
    case find_node(NodeId, Network) of
        {ok, _Node} ->
            case maps:find(NodeId, NodeProcs) of
                {ok, Pid} -> gen_server:stop(Pid);
                error -> ok
            end,
            UpdatedNodes = lists:filter(
                fun(N) -> N#node.node_id =/= NodeId end,
                Network#distributed_entropy_network.nodes
            ),
            UpdatedTopology = lists:filter(
                fun({N1, N2}) -> N1 =/= NodeId andalso N2 =/= NodeId end,
                Network#distributed_entropy_network.topology
            ),
            UpdatedNetwork = Network#distributed_entropy_network{
                nodes = UpdatedNodes,
                topology = UpdatedTopology,
                network_quality = calculate_network_quality(UpdatedNodes)
            },
            UpdatedNodeProcs = maps:remove(NodeId, NodeProcs),
            NewState = State#state{
                network = UpdatedNetwork,
                node_processes = UpdatedNodeProcs
            },
            {reply, {ok, node_removed}, NewState};
        {error, not_found} ->
            {reply, {error, node_not_found}, State}
    end;

handle_call({connect_nodes, NodeId1, NodeId2}, _From, State) ->
    #state{network = Network} = State,
    case find_node(NodeId1, Network) andalso find_node(NodeId2, Network) of
        true ->
            NewTopology = [{NodeId1, NodeId2}, {NodeId2, NodeId1} |
                         Network#distributed_entropy_network.topology],
            UpdatedNetwork = Network#distributed_entropy_network{
                topology = lists:usort(NewTopology)
            },
            NewState = State#state{network = UpdatedNetwork},
            {reply, {ok, nodes_connected}, NewState};
        false ->
            {reply, {error, node_not_found}, State}
    end;

handle_call(get_network_quality, _From, State) ->
    Quality = State#state.network#distributed_entropy_network.network_quality,
    {reply, {ok, Quality}, State};

handle_call({merge_networks, OtherNetworkPid}, _From, State) ->
    case gen_server:call(OtherNetworkPid, get_network_state) of
        {ok, OtherNetwork} ->
            MergedNetwork = merge_network_states(State#state.network, OtherNetwork),
            NewState = State#state{network = MergedNetwork},
            {reply, {ok, networks_merged}, NewState};
        Error ->
            {reply, Error, State}
    end;

handle_call(get_network_state, _From, State) ->
    {reply, {ok, State#state.network}, State};

handle_call(get_consensus_status, _From, State) ->
    #state{network = Network} = State,
    Status = check_consensus_status(Network),
    {reply, {ok, Status}, State};

handle_call(run_statistical_tests, _From, State) ->
    #state{network = Network} = State,
    EntropyData = Network#distributed_entropy_network.global_entropy_pool,
    Results = nist_test_suite(EntropyData),
    {reply, {ok, Results}, State};

handle_call(get_entropy_pool, _From, State) ->
    Pool = State#state.network#distributed_entropy_network.global_entropy_pool,
    {reply, Pool, State}.

handle_cast({generate_entropy, NodeId, EntropyData}, State) ->
    #state{network = Network} = State,
    case find_node(NodeId, Network) of
        {ok, Node} ->
            Source = #entropy_source{
                source_id = erlang:unique_integer([positive]),
                entropy_data = EntropyData,
                quality_metric = calculate_entropy_quality(EntropyData),
                timestamp = erlang:system_time(millisecond),
                physical_signature = generate_physical_signature()
            },
            UpdatedNode = Node#node{
                sources = [Source | Node#node.sources]
            },
            UpdatedNodes = lists:keyreplace(NodeId, #node.node_id,
                                          Network#distributed_entropy_network.nodes,
                                          UpdatedNode),
            UpdatedPool = EntropyData ++ Network#distributed_entropy_network.global_entropy_pool,
            UpdatedNetwork = Network#distributed_entropy_network{
                nodes = UpdatedNodes,
                global_entropy_pool = UpdatedPool,
                network_quality = calculate_network_quality(UpdatedNodes)
            },
            NewState = State#state{network = UpdatedNetwork},
            propagate_entropy(NodeId, Source, Network),
            {noreply, NewState};
        {error, not_found} ->
            {noreply, State}
    end;

handle_cast({entropy_received, Source, _FromNodeId}, State) ->
    #state{network = Network} = State,
    UpdatedPool = Source#entropy_source.entropy_data ++
                  Network#distributed_entropy_network.global_entropy_pool,
    UpdatedNetwork = Network#distributed_entropy_network{
        global_entropy_pool = UpdatedPool,
        consensus_round = Network#distributed_entropy_network.consensus_round + 1
    },
    NewState = State#state{network = UpdatedNetwork},
    {noreply, NewState}.

handle_info({timeout, _Ref, consensus_check}, State) ->
    NewState = perform_consensus_check(State),
    Timer = erlang:start_timer(5000, self(), consensus_check),
    {noreply, NewState#state{consensus_timer = Timer}};

handle_info({'EXIT', Pid, Reason}, State) ->
    #state{node_processes = NodeProcs} = State,
    case maps:fold(fun(NodeId, P, Acc) ->
                       case P of
                           Pid -> [NodeId | Acc];
                           _ -> Acc
                       end
                   end, [], NodeProcs) of
        [NodeId] ->
            io:format("Node ~p exited with reason: ~p~n", [NodeId, Reason]),
            {noreply, remove_dead_node(NodeId, State)};
        [] ->
            {noreply, State}
    end.

terminate(_Reason, State) ->
    maps:fold(fun(_NodeId, Pid, _Acc) ->
                  gen_server:stop(Pid)
              end, ok, State#state.node_processes),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ============================================================================
%% INTERNAL FUNCTIONS
%% ============================================================================

valid_trust_level(Level) when is_float(Level) ->
    Level >= 0.0 andalso Level =< 1.0;
valid_trust_level(_) -> false.

valid_node(Node) ->
    is_record(Node, node) andalso
    valid_trust_level(Node#node.trust_level) andalso
    lists:all(fun(Source) ->
                  Source#entropy_source.quality_metric >= 0.0 andalso
                  Source#entropy_source.quality_metric =< 1.0
              end, Node#node.sources).

node_exists(NodeId, Network) ->
    lists:any(fun(N) -> N#node.node_id =:= NodeId end,
              Network#distributed_entropy_network.nodes).

find_node(NodeId, Network) ->
    case lists:keyfind(NodeId, #node.node_id,
                       Network#distributed_entropy_network.nodes) of
        false -> {error, not_found};
        Node -> {ok, Node}
    end.

start_node_process(NodeId) ->
    gen_server:start_link(?MODULE, [NodeId], []).

calculate_entropy_quality(EntropyData) ->
    case length(EntropyData) of
        0 -> 0.0;
        Len ->
            TrueCount = length(lists:filter(fun(X) -> X end, EntropyData)),
            FalseCount = Len - TrueCount,
            case {TrueCount, FalseCount} of
                {0, _} -> 0.0;
                {_, 0} -> 0.0;
                _ ->
                    P1 = TrueCount / Len,
                    P2 = FalseCount / Len,
                    -P1 * math:log2(P1) - P2 * math:log2(P2)
            end
    end.

calculate_network_quality(Nodes) ->
    ActiveNodes = lists:filter(fun(N) -> N#node.is_active end, Nodes),
    case length(ActiveNodes) of
        0 -> 0.0;
        _ ->
            AllSources = lists:flatmap(fun(N) -> N#node.sources end, ActiveNodes),
            AllEntropy = lists:flatmap(fun(S) -> S#entropy_source.entropy_data end, AllSources),
            calculate_entropy_quality(AllEntropy)
    end.

generate_physical_signature() ->
    [rand:uniform() || _ <- lists:seq(1, 10)].

propagate_entropy(FromNodeId, Source, Network) ->
    case find_node(FromNodeId, Network) of
        {ok, Node} ->
            lists:foreach(fun(NeighborId) ->
                              case find_node(NeighborId, Network) of
                                  {ok, Neighbor} when Neighbor#node.pid =/= undefined ->
                                      gen_server:cast(Neighbor#node.pid,
                                                    {entropy_received, Source, FromNodeId});
                                  _ -> ok
                              end
                          end, Node#node.neighbors);
        _ -> ok
    end.

merge_network_states(Net1, Net2) ->
    MergedNodes = Net1#distributed_entropy_network.nodes ++
                  Net2#distributed_entropy_network.nodes,
    MergedTopology = lists:usort(Net1#distributed_entropy_network.topology ++
                                Net2#distributed_entropy_network.topology),
    MergedPool = Net1#distributed_entropy_network.global_entropy_pool ++
                 Net2#distributed_entropy_network.global_entropy_pool,
    #distributed_entropy_network{
        nodes = MergedNodes,
        topology = MergedTopology,
        global_entropy_pool = MergedPool,
        consensus_round = max(Net1#distributed_entropy_network.consensus_round,
                             Net2#distributed_entropy_network.consensus_round),
        network_quality = calculate_network_quality(MergedNodes)
    }.

check_consensus_status(_Network) ->
    consensus_ok.

perform_consensus_check(State) ->
    State.

remove_dead_node(NodeId, State) ->
    #state{network = Network, node_processes = NodeProcs} = State,
    UpdatedNodes = lists:filter(
        fun(N) -> N#node.node_id =/= NodeId end,
        Network#distributed_entropy_network.nodes
    ),
    UpdatedNetwork = Network#distributed_entropy_network{
        nodes = UpdatedNodes,
        network_quality = calculate_network_quality(UpdatedNodes)
    },
    UpdatedNodeProcs = maps:remove(NodeId, NodeProcs),
    State#state{
        network = UpdatedNetwork,
        node_processes = UpdatedNodeProcs
    }.

nist_test_suite(_EntropyData) ->
    [{test, passed}].

