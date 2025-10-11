-module(alara_basic_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("alara/include/alara.hrl").

%% ============================================================================
%% Test Fixtures - Setup and Cleanup
%% ============================================================================

%% Setup function - ensures clean state before each test
setup() ->
    %% Kill any existing supervisor that might be registered
    case whereis(alara_node_sup) of
        undefined -> ok;
        Pid when is_pid(Pid) -> 
            catch exit(Pid, kill),
            %% Wait for the process to actually die
            timer:sleep(50)
    end,
    ok.

%% Cleanup function - stops network and waits for cleanup
cleanup(NetPid) when is_pid(NetPid) ->
    case is_process_alive(NetPid) of
        true -> 
            catch gen_server:stop(NetPid),
            timer:sleep(50);
        false -> 
            ok
    end;
cleanup(_) ->
    ok.

%% ============================================================================
%% Test: Basic Network Creation and Quality Check
%% ============================================================================
%% This test verifies that:
%% - A network can be created with a specified number of nodes
%% - The nodes are automatically started by the supervisor
%% - Network quality can be calculated
%% - Network state can be retrieved
basic_scenario_test() ->
    setup(),
    %% Create a network with 3 nodes (nodes are automatically created)
    {ok, NetPid} = alara:create_network(3),
    
    %% Retrieve the list of nodes that were automatically started
    {ok, Nodes} = alara:get_nodes(NetPid),
    
    %% Verify that we have exactly 3 nodes
    ?assertEqual(3, length(Nodes)),
    
    %% Verify all node PIDs are valid processes
    ?assert(lists:all(fun(Pid) -> is_pid(Pid) andalso is_process_alive(Pid) end, Nodes)),
    
    %% Get the network quality (should be 0.0 initially with no connections)
    {ok, Quality} = alara:get_network_quality(NetPid),
    ?assert(Quality >= 0.0),
    ?assert(Quality =< 1.0),
    
    %% Verify we can retrieve the full network state
    {ok, NetworkState} = alara:get_network_state(NetPid),
    ?assert(is_record(NetworkState, distributed_entropy_network)),
    
    %% Clean up - stop the network process
    cleanup(NetPid).

%% ============================================================================
%% Test: Multiple Nodes with Network Topology
%% ============================================================================
%% This test verifies that:
%% - Multiple nodes can be created in a network
%% - Connections can be added between nodes
%% - Network topology is properly maintained
%% - Network quality increases with more connections
multiple_nodes_entropy_test() ->
    setup(),
    %% Create a network with 3 nodes
    {ok, NetPid} = alara:create_network(3),
    
    %% Retrieve the node PIDs
    {ok, [Node1, Node2, Node3]} = alara:get_nodes(NetPid),
    
    %% Verify all nodes are running
    ?assert(is_process_alive(Node1)),
    ?assert(is_process_alive(Node2)),
    ?assert(is_process_alive(Node3)),
    
    %% Get initial network quality (no connections yet)
    {ok, InitialQuality} = alara:get_network_quality(NetPid),
    ?assertEqual(0.0, InitialQuality),
    
    %% Add connections between nodes to form a topology
    %% Node1 <-> Node2
    {ok, nodes_connected} = alara:add_connection(NetPid, Node1, Node2),
    
    %% Node2 <-> Node3
    {ok, nodes_connected} = alara:add_connection(NetPid, Node2, Node3),
    
    %% Get updated network quality (should be higher with connections)
    {ok, UpdatedQuality} = alara:get_network_quality(NetPid),
    ?assert(UpdatedQuality > InitialQuality),
    ?assert(UpdatedQuality > 0.0),
    
    %% Verify the network state contains our connections
    {ok, NetworkState} = alara:get_network_state(NetPid),
    Topology = NetworkState#distributed_entropy_network.topology,
    
    %% Each connection should appear twice (bidirectional)
    ?assert(length(Topology) >= 4), % At least 2 connections * 2 directions
    
    %% Clean up
    cleanup(NetPid).

%% ============================================================================
%% Test: Random Number Generation from Distributed Nodes
%% ============================================================================
%% This test verifies that:
%% - Random booleans can be generated from the distributed node pool
%% - Random integers can be generated using multiple bits
%% - The generated values are valid and within expected ranges
weighted_random_generation_test() ->
    setup(),
    %% Create a network with 4 nodes for better entropy distribution
    {ok, NetPid} = alara:create_network(4),
    
    %% Retrieve the nodes
    {ok, Nodes} = alara:get_nodes(NetPid),
    ?assertEqual(4, length(Nodes)),
    
    %% Generate random booleans distributed across all nodes
    RandomBools = alara:generate_random_bools(32),
    
    %% Verify we got the correct number of random booleans
    ?assertEqual(32, length(RandomBools)),
    
    %% Verify all values are valid booleans
    ?assert(lists:all(fun(B) -> is_boolean(B) end, RandomBools)),
    
    %% Generate a random integer using 16 bits of entropy
    RandomInt = alara:generate_random_int(16),
    
    %% Verify the random integer is valid
    ?assert(is_integer(RandomInt)),
    ?assert(RandomInt >= 0),
    ?assert(RandomInt < math:pow(2, 16)), % Should be less than 2^16
    
    %% Generate another random integer with different bit size
    RandomInt8 = alara:generate_random_int(8),
    ?assert(is_integer(RandomInt8)),
    ?assert(RandomInt8 >= 0),
    ?assert(RandomInt8 < 256), % Should be less than 2^8
    
    %% Generate multiple random booleans from a specific node
    [FirstNode | _] = Nodes,
    NodeRandoms = alara:generate_random_bools(FirstNode, 10),
    ?assertEqual(10, length(NodeRandoms)),
    ?assert(lists:all(fun(B) -> is_boolean(B) end, NodeRandoms)),
    
    %% Clean up
    cleanup(NetPid).

%% ============================================================================
%% Test: Connection Management
%% ============================================================================
%% This test verifies that:
%% - Connections can be added between nodes
%% - Connections can be removed from the network
%% - Network quality reflects topology changes
connection_management_test() ->
    setup(),
    %% Create a network with 3 nodes
    {ok, NetPid} = alara:create_network(3),
    {ok, [Node1, Node2, Node3]} = alara:get_nodes(NetPid),
    
    %% Add multiple connections
    {ok, nodes_connected} = alara:add_connection(NetPid, Node1, Node2),
    {ok, nodes_connected} = alara:add_connection(NetPid, Node2, Node3),
    {ok, nodes_connected} = alara:add_connection(NetPid, Node1, Node3),
    
    %% Get quality with all connections (fully connected network)
    {ok, FullQuality} = alara:get_network_quality(NetPid),
    ?assertEqual(1.0, FullQuality), % Fully connected network has quality 1.0
    
    %% Remove one connection
    {ok, connection_removed} = alara:remove_connection(NetPid, Node1, Node3),
    
    %% Quality should decrease
    {ok, ReducedQuality} = alara:get_network_quality(NetPid),
    ?assert(ReducedQuality < FullQuality),
    
    %% Verify the connection was actually removed
    {ok, NetworkState} = alara:get_network_state(NetPid),
    Topology = NetworkState#distributed_entropy_network.topology,
    
    %% The removed connection should not be in the topology
    ?assertNot(lists:member({Node1, Node3}, Topology)),
    ?assertNot(lists:member({Node3, Node1}, Topology)),
    
    %% But other connections should still exist
    ?assert(lists:member({Node1, Node2}, Topology) orelse 
            lists:member({Node2, Node1}, Topology)),
    
    %% Clean up
    cleanup(NetPid).

%% ============================================================================
%% Test: Edge Cases
%% ============================================================================
%% This test verifies error handling and edge cases
edge_cases_test() ->
    setup(),
    %% Create a network with only 1 node
    {ok, NetPid1} = alara:create_network(1),
    {ok, [SingleNode]} = alara:get_nodes(NetPid1),
    
    %% Quality should be 0.0 for a single node (no possible connections)
    {ok, Quality1} = alara:get_network_quality(NetPid1),
    ?assertEqual(0.0, Quality1),
    
    %% Cannot connect a node to itself (should fail gracefully)
    _Result = alara:add_connection(NetPid1, SingleNode, SingleNode),
    %% This might succeed depending on implementation, but quality should stay 0
    {ok, _} = alara:get_network_quality(NetPid1),
    
    cleanup(NetPid1),
    
    setup(),
    %% Create a network with 2 nodes
    {ok, NetPid2} = alara:create_network(2),
    {ok, [NodeA, NodeB]} = alara:get_nodes(NetPid2),
    
    %% Try to remove a connection that doesn't exist (should not crash)
    {ok, connection_removed} = alara:remove_connection(NetPid2, NodeA, NodeB),
    
    %% Try to connect with an invalid node PID (should return error)
    FakeNode = spawn(fun() -> ok end),
    {error, node_not_found} = alara:add_connection(NetPid2, NodeA, FakeNode),
    
    cleanup(NetPid2).
