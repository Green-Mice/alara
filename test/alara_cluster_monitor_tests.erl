%% ============================================================================
%% alara_cluster_monitor_tests - Unit tests for the cluster monitor
%%
%% These tests exercise the monitor without real remote BEAM nodes.
%% Distributed integration tests (nodeup/nodedown from a real peer)
%% are in alara_cluster_tests.erl.
%% ============================================================================

-module(alara_cluster_monitor_tests).
-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

setup_no_remote() ->
    application:stop(alara),
    application:set_env(alara, remote_nodes, []),
    ok = application:start(alara).

setup_fake_remote() ->
    application:stop(alara),
    application:set_env(alara, remote_nodes, ['fake1@nowhere', 'fake2@nowhere']),
    ok = application:start(alara).

cleanup(_) ->
    application:stop(alara),
    application:unset_env(alara, remote_nodes).

%% ---------------------------------------------------------------------------
%% Tests
%% ---------------------------------------------------------------------------

%% ETS table exists after start
ets_exists_test() ->
    setup_no_remote(),
    ?assertNotEqual(undefined, ets:info(alara_cluster_nodes)),
    cleanup(ok).

%% No remote_nodes → both accessors return []
empty_remote_nodes_test() ->
    setup_no_remote(),
    ?assertEqual([], alara_cluster_monitor:get_reachable_nodes()),
    ?assertEqual([], alara_cluster_monitor:get_all_nodes()),
    cleanup(ok).

%% Configured fake nodes appear as 'down' (cannot connect to them)
fake_nodes_appear_as_down_test() ->
    setup_fake_remote(),
    All = lists:sort(alara_cluster_monitor:get_all_nodes()),
    ?assertEqual(2, length(All)),
    ?assert(lists:member({'fake1@nowhere', down}, All)),
    ?assert(lists:member({'fake2@nowhere', down}, All)),
    ?assertEqual([], alara_cluster_monitor:get_reachable_nodes()),
    cleanup(ok).

%% nodeup message → ETS updated to 'up'
nodeup_updates_ets_test() ->
    setup_fake_remote(),
    whereis(alara_cluster_monitor) ! {nodeup, 'fake1@nowhere'},
    timer:sleep(100),
    All = alara_cluster_monitor:get_all_nodes(),
    ?assert(lists:member({'fake1@nowhere', up}, All)),
    cleanup(ok).

%% nodedown message → ETS updated to 'down'
nodedown_updates_ets_test() ->
    setup_fake_remote(),
    Mon = whereis(alara_cluster_monitor),
    Mon ! {nodeup, 'fake1@nowhere'},
    timer:sleep(50),
    Mon ! {nodedown, 'fake1@nowhere'},
    timer:sleep(50),
    All = alara_cluster_monitor:get_all_nodes(),
    ?assert(lists:member({'fake1@nowhere', down}, All)),
    cleanup(ok).

%% Unknown node in nodeup/nodedown → ignored, no crash
unknown_node_ignored_test() ->
    setup_no_remote(),
    Mon = whereis(alara_cluster_monitor),
    Mon ! {nodeup, 'stranger@host'},
    Mon ! {nodedown, 'stranger@host'},
    timer:sleep(50),
    ?assert(is_process_alive(Mon)),
    ?assertEqual([], alara_cluster_monitor:get_all_nodes()),
    cleanup(ok).

%% reconnect_tick with all nodes unreachable → no crash, nodes still down
reconnect_tick_no_crash_test() ->
    setup_fake_remote(),
    Mon = whereis(alara_cluster_monitor),
    Mon ! reconnect_tick,
    timer:sleep(100),
    ?assert(is_process_alive(Mon)),
    ?assertEqual([], alara_cluster_monitor:get_reachable_nodes()),
    cleanup(ok).

%% Accessors return [] safely when ETS table does not exist (monitor down)
ets_missing_returns_empty_test() ->
    application:stop(alara),
    ?assertEqual([], alara_cluster_monitor:get_reachable_nodes()),
    ?assertEqual([], alara_cluster_monitor:get_all_nodes()).
