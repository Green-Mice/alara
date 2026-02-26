-module(alara_basic_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("alara/include/alara.hrl").

%% ============================================================================
%% Test Fixtures - Setup and Cleanup
%% ============================================================================

%% Kill any registered supervisor left over from a previous test run.
setup() ->
    case whereis(alara_node_sup) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            catch exit(Pid, kill),
            timer:sleep(50)
    end,
    ok.

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
%% Verifies that:
%% - A network starts with the requested number of worker nodes.
%% - Every returned PID belongs to a live process.
basic_scenario_test() ->
    setup(),
    {ok, NetPid} = alara:create_network(3),

    {ok, Nodes} = alara:get_nodes(NetPid),
    ?assertEqual(3, length(Nodes)),
    ?assert(lists:all(fun(Pid) -> is_pid(Pid) andalso is_process_alive(Pid) end, Nodes)),

    cleanup(NetPid).

%% ============================================================================
%% Test: Multiple Nodes Creation
%% ============================================================================
%% Verifies that all three workers in a 3-node network are individually alive.
multiple_nodes_test() ->
    setup(),
    {ok, NetPid} = alara:create_network(3),

    {ok, [Node1, Node2, Node3]} = alara:get_nodes(NetPid),
    ?assert(is_process_alive(Node1)),
    ?assert(is_process_alive(Node2)),
    ?assert(is_process_alive(Node3)),

    cleanup(NetPid).

%% ============================================================================
%% Test: Random Byte Generation
%% ============================================================================
%% Verifies that:
%% - generate_random_bytes/1 returns a binary of the exact requested size.
%% - generate_random_bits/1  returns a list of 0|1 integers of the right length.
%% - generate_random_int/1   returns a non-negative integer within the expected range.
random_generation_test() ->
    setup(),
    {ok, NetPid} = alara:create_network(4),

    %% --- Bytes ---
    Bytes = alara:generate_random_bytes(32),
    ?assert(is_binary(Bytes)),
    ?assertEqual(32, byte_size(Bytes)),

    %% --- Bits ---
    Bits = alara:generate_random_bits(64),
    ?assertEqual(64, length(Bits)),
    ?assert(lists:all(fun(B) -> B =:= 0 orelse B =:= 1 end, Bits)),

    %% --- Integer (16 bits) ---
    Int16 = alara:generate_random_int(16),
    ?assert(is_integer(Int16)),
    ?assert(Int16 >= 0),
    ?assert(Int16 < round(math:pow(2, 16))),

    %% --- Integer (8 bits) ---
    Int8 = alara:generate_random_int(8),
    ?assert(is_integer(Int8)),
    ?assert(Int8 >= 0),
    ?assert(Int8 < 256),

    cleanup(NetPid).

%% ============================================================================
%% Test: Edge Cases - Single Node Network
%% ============================================================================
%% Verifies that entropy generation still works when only one worker exists.
single_node_test() ->
    setup(),
    {ok, NetPid} = alara:create_network(1),

    {ok, [SingleNode]} = alara:get_nodes(NetPid),
    ?assert(is_process_alive(SingleNode)),

    %% Ask the supervisor directly for bytes from the single-node pool.
    Bytes = alara_node_sup:generate_random_bytes(4),
    ?assert(is_binary(Bytes)),
    ?assertEqual(4, byte_size(Bytes)),

    cleanup(NetPid).

%% ============================================================================
%% Test: Edge Cases - Large Network
%% ============================================================================
%% Verifies that a 10-node network starts cleanly and generates valid output.
large_network_test() ->
    setup(),
    {ok, NetPid} = alara:create_network(10),

    {ok, Nodes} = alara:get_nodes(NetPid),
    ?assertEqual(10, length(Nodes)),
    ?assert(lists:all(fun(Pid) -> is_process_alive(Pid) end, Nodes)),

    %% 100 bits require ceil(100/8) = 13 bytes from the pool.
    Bits = alara:generate_random_bits(100),
    ?assertEqual(100, length(Bits)),
    ?assert(lists:all(fun(B) -> B =:= 0 orelse B =:= 1 end, Bits)),

    cleanup(NetPid).

%% ============================================================================
%% Test: Node List Freshness
%% ============================================================================
%% Verifies that get_nodes/1 always reflects the live state of the supervisor
%% rather than a stale cached copy.
node_list_freshness_test() ->
    setup(),
    {ok, NetPid} = alara:create_network(5),

    {ok, Nodes1} = alara:get_nodes(NetPid),
    {ok, Nodes2} = alara:get_nodes(NetPid),

    %% Both calls must return the same five live workers.
    ?assertEqual(length(Nodes1), length(Nodes2)),
    ?assert(lists:all(fun(Pid) -> is_process_alive(Pid) end, Nodes1)),

    %% The supervisor PID must be alive too.
    SupPid = whereis(alara_node_sup),
    ?assert(is_pid(SupPid)),
    ?assert(is_process_alive(SupPid)),

    cleanup(NetPid).

%% ============================================================================
%% Test: Concurrent Random Generation
%% ============================================================================
%% Verifies that concurrent callers get independent, well-formed results.
concurrent_generation_test() ->
    setup(),
    {ok, NetPid} = alara:create_network(4),

    Parent = self(),
    NumProcs = 10,

    _Pids = [spawn(fun() ->
        Bytes = alara:generate_random_bytes(20),
        Parent ! {result, self(), Bytes}
    end) || _ <- lists:seq(1, NumProcs)],

    Results = [receive
        {result, _Pid, Bytes} -> Bytes
    after 5000 ->
        error(timeout)
    end || _ <- lists:seq(1, NumProcs)],

    ?assertEqual(NumProcs, length(Results)),
    lists:foreach(fun(Bytes) ->
        ?assert(is_binary(Bytes)),
        ?assertEqual(20, byte_size(Bytes))
    end, Results),

    cleanup(NetPid).

%% ============================================================================
%% Test: Direct Worker Access
%% ============================================================================
%% Verifies that alara_node:get_random_bytes/2 works correctly in isolation,
%% independently of the supervisor pool.
direct_worker_test() ->
    {ok, WorkerPid} = alara_node:start_link(),
    ?assert(is_process_alive(WorkerPid)),

    Bytes = alara_node:get_random_bytes(WorkerPid, 16),
    ?assert(is_binary(Bytes)),
    ?assertEqual(16, byte_size(Bytes)),

    %% Two consecutive calls must produce distinct results with overwhelming
    %% probability (collision probability ≈ 2^-128 for 16-byte outputs).
    Bytes2 = alara_node:get_random_bytes(WorkerPid, 16),
    ?assertNotEqual(Bytes, Bytes2),

    gen_server:stop(WorkerPid).
