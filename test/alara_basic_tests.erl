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
%% Test: Basic Network Creation
%% ============================================================================
%% This test verifies that:
%% - A network can be created with a specified number of nodes
%% - The nodes are automatically started by the supervisor
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

    %% Verify we can retrieve the full network state
    {ok, NetworkState} = alara:get_network_state(NetPid),
    ?assert(is_record(NetworkState, state)),
    
    %% Verify the state contains our nodes
    ?assertEqual(Nodes, NetworkState#state.nodes),

    %% Clean up - stop the network process
    cleanup(NetPid).

%% ============================================================================
%% Test: Multiple Nodes Creation
%% ============================================================================
%% This test verifies that:
%% - Multiple nodes can be created in a network
%% - All nodes are running and accessible
multiple_nodes_test() ->
    setup(),
    %% Create a network with 3 nodes
    {ok, NetPid} = alara:create_network(3),

    %% Retrieve the node PIDs
    {ok, [Node1, Node2, Node3]} = alara:get_nodes(NetPid),

    %% Verify all nodes are running
    ?assert(is_process_alive(Node1)),
    ?assert(is_process_alive(Node2)),
    ?assert(is_process_alive(Node3)),

    %% Verify the network state contains all nodes
    {ok, NetworkState} = alara:get_network_state(NetPid),
    ?assertEqual(3, length(NetworkState#state.nodes)),

    %% Clean up
    cleanup(NetPid).

%% ============================================================================
%% Test: Random Number Generation from Distributed Nodes
%% ============================================================================
%% This test verifies that:
%% - Random booleans can be generated from the distributed node pool
%% - Random integers can be generated using multiple bits
%% - The generated values are valid and within expected ranges
random_generation_test() ->
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
%% Test: Edge Cases - Single Node Network
%% ============================================================================
%% This test verifies that a single-node network works correctly
single_node_test() ->
    setup(),
    %% Create a network with only 1 node
    {ok, NetPid} = alara:create_network(1),
    {ok, [SingleNode]} = alara:get_nodes(NetPid),

    %% Verify the node is running
    ?assert(is_process_alive(SingleNode)),

    %% Verify we can get random values from it
    RandomBool = alara:generate_random_bools(SingleNode, 1),
    ?assertEqual(1, length(RandomBool)),
    ?assert(is_boolean(hd(RandomBool))),

    cleanup(NetPid).

%% ============================================================================
%% Test: Edge Cases - Large Network
%% ============================================================================
%% This test verifies that larger networks can be created
large_network_test() ->
    setup(),
    %% Create a network with 10 nodes
    {ok, NetPid} = alara:create_network(10),
    {ok, Nodes} = alara:get_nodes(NetPid),

    %% Verify we have 10 nodes
    ?assertEqual(10, length(Nodes)),

    %% Verify all nodes are alive
    ?assert(lists:all(fun(Pid) -> is_process_alive(Pid) end, Nodes)),

    %% Generate random values from the large network
    RandomBools = alara:generate_random_bools(100),
    ?assertEqual(100, length(RandomBools)),

    cleanup(NetPid).

%% ============================================================================
%% Test: Network State Persistence
%% ============================================================================
%% This test verifies that the network state remains consistent
state_consistency_test() ->
    setup(),
    %% Create a network
    {ok, NetPid} = alara:create_network(5),

    %% Get state multiple times
    {ok, State1} = alara:get_network_state(NetPid),
    {ok, State2} = alara:get_network_state(NetPid),

    %% Verify states are consistent
    ?assertEqual(State1#state.nodes, State2#state.nodes),
    ?assertEqual(State1#state.node_supervisor, State2#state.node_supervisor),

    %% Verify all nodes in state are still alive
    Nodes = State1#state.nodes,
    ?assert(lists:all(fun(Pid) -> is_process_alive(Pid) end, Nodes)),

    cleanup(NetPid).

%% ============================================================================
%% Test: Concurrent Random Generation
%% ============================================================================
%% This test verifies that multiple processes can generate random values
%% concurrently without issues
concurrent_generation_test() ->
    setup(),
    {ok, NetPid} = alara:create_network(4),
    {ok, _Nodes} = alara:get_nodes(NetPid),

    %% Spawn multiple processes that generate random values concurrently
    Parent = self(),
    NumProcesses = 10,
    
    Pids = [spawn(fun() ->
        Randoms = alara:generate_random_bools(20),
        Parent ! {result, self(), Randoms}
    end) || _ <- lists:seq(1, NumProcesses)],

    %% Collect all results
    Results = [receive
        {result, Pid, Randoms} -> Randoms
    after 5000 ->
        error(timeout)
    end || Pid <- Pids],

    %% Verify we got all results
    ?assertEqual(NumProcesses, length(Results)),

    %% Verify each result is valid
    lists:foreach(fun(Randoms) ->
        ?assertEqual(20, length(Randoms)),
        ?assert(lists:all(fun(B) -> is_boolean(B) end, Randoms))
    end, Results),

    cleanup(NetPid).
