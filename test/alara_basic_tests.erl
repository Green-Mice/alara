-module(alara_basic_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================================
%% Test Fixtures - Setup and Cleanup
%% ============================================================================

%% Start alara with a given pool size, stopping any previous instance first.
setup(PoolSize) ->
    application:stop(alara),
    application:set_env(alara, pool_size, PoolSize),
    ok = application:start(alara).

cleanup(_) ->
    application:stop(alara).

%% ============================================================================
%% Test: Basic Network Creation
%% ============================================================================
%% Verifies that a pool starts with the requested number of worker nodes
%% and that every returned PID belongs to a live process.
basic_scenario_test() ->
    setup(3),
    Nodes = alara:get_nodes(),
    ?assertEqual(3, length(Nodes)),
    ?assert(lists:all(fun(Pid) -> is_pid(Pid) andalso is_process_alive(Pid) end, Nodes)),
    cleanup(ok).

%% ============================================================================
%% Test: Multiple Nodes Creation
%% ============================================================================
%% Verifies that all three workers in a 3-node pool are individually alive.
multiple_nodes_test() ->
    setup(3),
    [Node1, Node2, Node3] = alara:get_nodes(),
    ?assert(is_process_alive(Node1)),
    ?assert(is_process_alive(Node2)),
    ?assert(is_process_alive(Node3)),
    cleanup(ok).

%% ============================================================================
%% Test: Random Byte Generation
%% ============================================================================
%% Verifies that:
%% - generate_random_bytes/1 returns a binary of the exact requested size.
%% - generate_random_bits/1  returns a list of 0|1 integers of the right length.
%% - generate_random_int/1   returns a non-negative integer within the expected range.
random_generation_test() ->
    setup(4),

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

    cleanup(ok).

%% ============================================================================
%% Test: Edge Cases - Single Node Pool
%% ============================================================================
%% Verifies that entropy generation still works when only one worker exists.
single_node_test() ->
    setup(1),
    [SingleNode] = alara:get_nodes(),
    ?assert(is_process_alive(SingleNode)),

    Bytes = alara:generate_random_bytes(4),
    ?assert(is_binary(Bytes)),
    ?assertEqual(4, byte_size(Bytes)),

    cleanup(ok).

%% ============================================================================
%% Test: Edge Cases - Large Pool
%% ============================================================================
%% Verifies that a 10-node pool starts cleanly and generates valid output.
large_network_test() ->
    setup(10),
    Nodes = alara:get_nodes(),
    ?assertEqual(10, length(Nodes)),
    ?assert(lists:all(fun(Pid) -> is_process_alive(Pid) end, Nodes)),

    %% 100 bits require ceil(100/8) = 13 bytes from the pool.
    Bits = alara:generate_random_bits(100),
    ?assertEqual(100, length(Bits)),
    ?assert(lists:all(fun(B) -> B =:= 0 orelse B =:= 1 end, Bits)),

    cleanup(ok).

%% ============================================================================
%% Test: Node List Freshness
%% ============================================================================
%% Verifies that get_nodes/0 always reflects the live state of the supervisor.
node_list_freshness_test() ->
    setup(5),
    Nodes1 = alara:get_nodes(),
    Nodes2 = alara:get_nodes(),

    ?assertEqual(length(Nodes1), length(Nodes2)),
    ?assert(lists:all(fun(Pid) -> is_process_alive(Pid) end, Nodes1)),

    SupPid = whereis(alara_node_sup),
    ?assert(is_pid(SupPid)),
    ?assert(is_process_alive(SupPid)),

    cleanup(ok).

%% ============================================================================
%% Test: Concurrent Random Generation
%% ============================================================================
%% Verifies that concurrent callers get independent, well-formed results.
concurrent_generation_test() ->
    setup(4),
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

    cleanup(ok).

%% ============================================================================
%% Test: Direct Worker Access
%% ============================================================================
%% Verifies that alara_node:get_random_bytes/2 works correctly in isolation,
%% independently of the pool.
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

%% ============================================================================
%% Test: Worker crash does not hang generate_random_bytes
%% ============================================================================
%% Kills a worker right before a generation call. The call must return
%% promptly — either with bytes (supervisor restarted the worker in time)
%% or with {error, ...}. A hang would cause this test to timeout.
worker_crash_no_hang_test_() ->
    {timeout, 3, fun() ->
        setup(2),
        [Worker | _] = alara:get_nodes(),
        %% Kill the worker; the spawned lambda inside collect_entropy
        %% will get a 'DOWN' and return {error, {worker_died, _}}.
        Ref = monitor(process, Worker),
        exit(Worker, kill),
        receive {'DOWN', Ref, process, Worker, _} -> ok end,
        %% Must complete without hanging.
        Result = alara:generate_random_bytes(16),
        ?assert(is_binary(Result) orelse element(1, Result) =:= error),
        cleanup(ok)
    end}.

%% ============================================================================
%% Test: Supervision tree includes cluster monitor
%% ============================================================================
supervision_tree_test() ->
    setup(2),
    ?assert(is_pid(whereis(alara_sup))),
    ?assert(is_pid(whereis(alara_node_sup))),
    ?assert(is_pid(whereis(alara_cluster_monitor))),
    ?assert(is_process_alive(whereis(alara_sup))),
    ?assert(is_process_alive(whereis(alara_node_sup))),
    ?assert(is_process_alive(whereis(alara_cluster_monitor))),
    cleanup(ok).

%% ============================================================================
%% Test: get_cluster_nodes/0 returns correct structure
%% ============================================================================
get_cluster_nodes_test() ->
    setup(3),
    Map = alara:get_cluster_nodes(),
    %% Must be a map with both keys.
    ?assert(is_map(Map)),
    ?assert(maps:is_key(local, Map)),
    ?assert(maps:is_key(remote, Map)),
    %% Local: 3 live PIDs (pool_size = 3).
    Local = maps:get(local, Map),
    ?assertEqual(3, length(Local)),
    ?assert(lists:all(fun is_pid/1, Local)),
    %% Remote: empty list (no remote_nodes in test config).
    ?assertEqual([], maps:get(remote, Map)),
    cleanup(ok).

%% ============================================================================
%% Test: add_node/0 increases the pool size by exactly 1
%% ============================================================================
add_node_increases_pool_test() ->
    setup(2),
    Before = length(alara:get_nodes()),
    {ok, _} = alara_node_sup:add_node(),
    After = length(alara:get_nodes()),
    ?assertEqual(Before + 1, After),
    cleanup(ok).

%% ============================================================================
%% Test: generate_random_bytes returns correct size for every N in 1..64
%% ============================================================================
generate_bytes_all_sizes_test() ->
    setup(3),
    lists:foreach(fun(N) ->
        Bytes = alara:generate_random_bytes(N),
        ?assert(is_binary(Bytes)),
        ?assertEqual(N, byte_size(Bytes))
    end, lists:seq(1, 64)),
    cleanup(ok).

%% ============================================================================
%% Test: generate_random_int(8) always returns a value in [0, 255]
%% ============================================================================
generate_int_range_test() ->
    setup(2),
    lists:foreach(fun(_) ->
        V = alara:generate_random_int(8),
        ?assert(is_integer(V)),
        ?assert(V >= 0),
        ?assert(V =< 255)
    end, lists:seq(1, 1000)),
    cleanup(ok).

%% ============================================================================
%% Test: generate_random_bits always returns exactly N bits, all 0 or 1
%% ============================================================================
generate_bits_property_test() ->
    setup(2),
    lists:foreach(fun(N) ->
        Bits = alara:generate_random_bits(N),
        ?assertEqual(N, length(Bits)),
        ?assert(lists:all(fun(B) -> B =:= 0 orelse B =:= 1 end, Bits))
    end, lists:seq(1, 128)),
    cleanup(ok).

%% ============================================================================
%% Test: 50 concurrent callers each get a distinct 32-byte result
%%
%% Collision probability for distinct honest outputs: ≈ 2^-256 per pair.
%% ============================================================================
concurrent_no_duplicates_test() ->
    setup(4),
    Parent  = self(),
    NumProcs = 50,
    [spawn(fun() ->
        Bytes = alara:generate_random_bytes(32),
        Parent ! {result, Bytes}
    end) || _ <- lists:seq(1, NumProcs)],
    Results = [receive
        {result, B} -> B
    after 5000 ->
        error(timeout)
    end || _ <- lists:seq(1, NumProcs)],
    ?assertEqual(NumProcs, length(Results)),
    %% All distinct.
    ?assertEqual(NumProcs, length(lists:usort(Results))),
    cleanup(ok).

%% ============================================================================
%% Test: killing all workers is handled gracefully — no hang, no crash
%%
%% Kill every worker in a 3-node pool. The supervisor restarts them, but the
%% call made immediately after killing may see {error, _} or succeed if a
%% worker restarted in time. Either is acceptable — the call must not hang.
%% ============================================================================
all_workers_crash_graceful_test_() ->
    {timeout, 5, fun() ->
        setup(3),
        Refs = [{W, monitor(process, W)} || W <- alara:get_nodes()],
        [exit(W, kill) || {W, _} <- Refs],
        [receive {'DOWN', Ref, process, W, _} -> ok end || {W, Ref} <- Refs],
        Result = alara:generate_random_bytes(16),
        ?assert(is_binary(Result) orelse element(1, Result) =:= error),
        cleanup(ok)
    end}.
