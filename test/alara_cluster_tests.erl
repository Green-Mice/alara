%% ============================================================================
%% alara_cluster_tests - Distributed integration tests
%%
%% Uses peer:start_link/1 (OTP 25+) to start real child BEAM nodes.
%% Requires distributed Erlang — the suite starts it automatically via
%% net_kernel:start/1 if the test node is not already distributed.
%%
%% Run with: rebar3 eunit --module=alara_cluster_tests
%% ============================================================================

-module(alara_cluster_tests).
-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% Suite entry point — ensures distributed Erlang is available
%% ---------------------------------------------------------------------------

cluster_test_() ->
    case ensure_distributed() of
        ok ->
            cluster_suite();
        {error, Reason} ->
            {skip, lists:flatten(io_lib:format("Distributed Erlang unavailable: ~p", [Reason]))}
    end.

ensure_distributed() ->
    case node() of
        nonode@nohost ->
            case net_kernel:start([alara_cluster_test, shortnames]) of
                {ok, _}                       -> ok;
                {error, {already_started, _}} -> ok;
                {error, Reason}               -> {error, Reason}
            end;
        _ ->
            ok
    end.

%% ---------------------------------------------------------------------------
%% Peer helpers
%% ---------------------------------------------------------------------------

%% Start a peer BEAM node with alara loaded and started.
start_peer() ->
    EbinDir = code:lib_dir(alara, ebin),
    Name    = list_to_atom("alara_peer_" ++
                  integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer, PeerNode} = peer:start_link(#{
        name => Name,
        args => ["-pa", EbinDir]
    }),
    ok = erpc:call(PeerNode, application, set_env, [alara, pool_size, 2]),
    {ok, _} = erpc:call(PeerNode, application, ensure_all_started, [alara]),
    {Peer, PeerNode}.

stop_peer(Peer) ->
    peer:stop(Peer).

%% Configure local alara to treat PeerNode as a remote node.
setup_local_with_remote(PeerNode) ->
    application:stop(alara),
    application:set_env(alara, remote_nodes, [PeerNode]),
    application:set_env(alara, pool_size, 2),
    ok = application:start(alara).

teardown_local() ->
    application:stop(alara),
    application:unset_env(alara, remote_nodes),
    application:set_env(alara, pool_size, 3).

%% ---------------------------------------------------------------------------
%% Tests
%% ---------------------------------------------------------------------------

cluster_suite() ->
    [
        {"peer shows as up in cluster view",     fun cluster_view_test/0},
        {"generation works with remote peer",    fun remote_contributes_test/0},
        {"dead remote node: local fallback",     fun remote_node_down_graceful_test/0},
        {"unconfigured node: local fallback",    fun unconfigured_remote_test/0},
        {"peer goes down: marked down in ETS",   fun remote_node_stops_marks_down_test/0},
        {"concurrent distributed generation",    fun concurrent_distributed_test/0},
        {"empty remote_nodes: normal operation", fun empty_remote_nodes_noop_test/0}
    ].

%% Peer shows as 'up' in get_cluster_nodes/0
cluster_view_test() ->
    {Peer, PeerNode} = start_peer(),
    setup_local_with_remote(PeerNode),
    Remote = maps:get(remote, alara:get_cluster_nodes()),
    ?assert(lists:member({PeerNode, up}, Remote)),
    teardown_local(),
    stop_peer(Peer).

%% generate_random_bytes works when a remote peer is configured and up
remote_contributes_test() ->
    {Peer, PeerNode} = start_peer(),
    setup_local_with_remote(PeerNode),
    Bytes = alara:generate_random_bytes(32),
    ?assert(is_binary(Bytes)),
    ?assertEqual(32, byte_size(Bytes)),
    teardown_local(),
    stop_peer(Peer).

%% Configured but unreachable node → local fallback, still returns bytes
remote_node_down_graceful_test() ->
    application:stop(alara),
    application:set_env(alara, remote_nodes, ['does_not_exist@nowhere']),
    application:set_env(alara, pool_size, 3),
    ok = application:start(alara),
    Bytes = alara:generate_random_bytes(16),
    ?assert(is_binary(Bytes)),
    ?assertEqual(16, byte_size(Bytes)),
    teardown_local().

%% No remote_nodes config → get_cluster_nodes returns empty remote list,
%% generation identical to 0.1.8
empty_remote_nodes_noop_test() ->
    application:stop(alara),
    application:set_env(alara, remote_nodes, []),
    application:set_env(alara, pool_size, 3),
    ok = application:start(alara),
    Map = alara:get_cluster_nodes(),
    ?assertEqual([], maps:get(remote, Map)),
    ?assertEqual(3, length(maps:get(local, Map))),
    Bytes = alara:generate_random_bytes(32),
    ?assert(is_binary(Bytes)),
    ?assertEqual(32, byte_size(Bytes)),
    teardown_local().

%% peer goes down → monitor marks it 'down', generation still works (local)
remote_node_stops_marks_down_test() ->
    {Peer, PeerNode} = start_peer(),
    setup_local_with_remote(PeerNode),
    %% Verify up initially.
    Remote1 = maps:get(remote, alara:get_cluster_nodes()),
    ?assert(lists:member({PeerNode, up}, Remote1)),
    %% Stop the peer → {nodedown, PeerNode} fires to the monitor.
    stop_peer(Peer),
    timer:sleep(500),
    %% Now marked as down.
    Remote2 = maps:get(remote, alara:get_cluster_nodes()),
    ?assert(lists:member({PeerNode, down}, Remote2)),
    %% Generation still works (local pool).
    Bytes = alara:generate_random_bytes(16),
    ?assert(is_binary(Bytes)),
    ?assertEqual(16, byte_size(Bytes)),
    teardown_local().

%% 20 concurrent callers with one remote peer — all get valid, distinct results
concurrent_distributed_test() ->
    {Peer, PeerNode} = start_peer(),
    setup_local_with_remote(PeerNode),
    Parent   = self(),
    NumProcs = 20,
    [spawn(fun() ->
        Bytes = alara:generate_random_bytes(32),
        Parent ! {result, Bytes}
    end) || _ <- lists:seq(1, NumProcs)],
    Results = [receive
        {result, B} -> B
    after 10000 ->
        error(timeout)
    end || _ <- lists:seq(1, NumProcs)],
    ?assertEqual(NumProcs, length(Results)),
    lists:foreach(fun(B) ->
        ?assert(is_binary(B)),
        ?assertEqual(32, byte_size(B))
    end, Results),
    %% All distinct.
    ?assertEqual(NumProcs, length(lists:usort(Results))),
    teardown_local(),
    stop_peer(Peer).

%% peer connected but not in remote_nodes → not in cluster view, not contacted
unconfigured_remote_test() ->
    {Peer, PeerNode} = start_peer(),
    %% Local alara has no remote_nodes configured.
    application:stop(alara),
    application:set_env(alara, remote_nodes, []),
    application:set_env(alara, pool_size, 3),
    ok = application:start(alara),
    Remote = maps:get(remote, alara:get_cluster_nodes()),
    %% PeerNode must NOT appear — it's not configured.
    ?assertNot(lists:keymember(PeerNode, 1, Remote)),
    teardown_local(),
    stop_peer(Peer).
