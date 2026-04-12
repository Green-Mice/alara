%% ============================================================================
%% alara_cluster_tests - Distributed integration tests
%%
%% Uses peer:start_link/1 (OTP 25+) to start real child BEAM nodes.
%% Requires distributed Erlang — the suite starts it automatically via
%% net_kernel:start/1 if the test node is not already distributed.
%%
%% Each test uses try/after to guarantee cleanup (teardown_local/stop_peer)
%% runs even when an assertion fails mid-test.
%%
%% Run with: rebar3 eunit --module=alara_cluster_tests
%% ============================================================================

-module(alara_cluster_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pool size used in tests that configure local alara without a remote peer.
-define(LOCAL_POOL, 3).

%% ---------------------------------------------------------------------------
%% Suite entry point — ensures distributed Erlang is available
%% ---------------------------------------------------------------------------

cluster_test_() ->
    case ensure_distributed() of
        ok         -> cluster_suite();
        {error, _} -> []
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
%% Infrastructure helpers
%% ---------------------------------------------------------------------------

%% Start a peer BEAM node with alara loaded and started.
%% Note: peer:start_link/1 inherits the parent node's cookie by default (OTP 25+).
%% If the erpc setup calls fail after the peer is live, the peer is explicitly
%% stopped before re-raising to avoid resource leaks.
start_peer() ->
    EbinDir = code:lib_dir(alara, ebin),
    Name    = list_to_atom("alara_peer_" ++
                  integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer, PeerNode} = peer:start_link(#{
        name => Name,
        args => ["-pa", EbinDir]
    }),
    try
        ok = erpc:call(PeerNode, application, set_env, [alara, pool_size, 2]),
        {ok, _} = erpc:call(PeerNode, application, ensure_all_started, [alara])
    catch
        Class:Reason:Stack ->
            peer:stop(Peer),
            erlang:raise(Class, Reason, Stack)
    end,
    {Peer, PeerNode}.

stop_peer(Peer) ->
    peer:stop(Peer).

%% Restart local alara with PeerNode configured as a remote node.
setup_local_with_remote(PeerNode) ->
    _ = application:stop(alara),
    application:set_env(alara, remote_nodes, [PeerNode]),
    application:set_env(alara, pool_size, 2),
    ok = application:start(alara).

%% Stop local alara and clear all test-specific env keys.
teardown_local() ->
    _ = application:stop(alara),
    application:unset_env(alara, remote_nodes),
    application:unset_env(alara, pool_size).

%% Poll until Fun() returns true, or fail after Timeout ms.
%% Used instead of fixed timer:sleep to avoid timing-dependent failures.
wait_until(Fun, Timeout) ->
    wait_until(Fun, Timeout, 50).

wait_until(_Fun, Timeout, _Interval) when Timeout =< 0 ->
    error(wait_until_timeout);
wait_until(Fun, Timeout, Interval) ->
    case Fun() of
        true  -> ok;
        false ->
            timer:sleep(Interval),
            wait_until(Fun, Timeout - Interval, Interval)
    end.

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
    try
        setup_local_with_remote(PeerNode),
        Remote = maps:get(remote, alara:get_cluster_nodes()),
        ?assert(lists:member({PeerNode, up}, Remote))
    after
        teardown_local(),
        stop_peer(Peer)
    end.

%% generate_random_bytes works when a remote peer is configured and up
remote_contributes_test() ->
    {Peer, PeerNode} = start_peer(),
    try
        setup_local_with_remote(PeerNode),
        Bytes = alara:generate_random_bytes(32),
        ?assert(is_binary(Bytes)),
        ?assertEqual(32, byte_size(Bytes))
    after
        teardown_local(),
        stop_peer(Peer)
    end.

%% Configured but unreachable node → local fallback, still returns bytes
remote_node_down_graceful_test() ->
    _ = application:stop(alara),
    application:set_env(alara, remote_nodes, ['does_not_exist@nowhere']),
    application:set_env(alara, pool_size, ?LOCAL_POOL),
    try
        ok = application:start(alara),
        Bytes = alara:generate_random_bytes(16),
        ?assert(is_binary(Bytes)),
        ?assertEqual(16, byte_size(Bytes))
    after
        teardown_local()
    end.

%% No remote_nodes config → get_cluster_nodes returns empty remote list,
%% generation identical to 0.1.8
empty_remote_nodes_noop_test() ->
    _ = application:stop(alara),
    application:set_env(alara, remote_nodes, []),
    application:set_env(alara, pool_size, ?LOCAL_POOL),
    try
        ok = application:start(alara),
        Map = alara:get_cluster_nodes(),
        ?assertEqual([], maps:get(remote, Map)),
        ?assertEqual(?LOCAL_POOL, length(maps:get(local, Map))),
        Bytes = alara:generate_random_bytes(32),
        ?assert(is_binary(Bytes)),
        ?assertEqual(32, byte_size(Bytes))
    after
        teardown_local()
    end.

%% peer goes down → monitor marks it 'down', generation still works (local pool)
remote_node_stops_marks_down_test() ->
    {Peer, PeerNode} = start_peer(),
    try
        setup_local_with_remote(PeerNode),
        Remote1 = maps:get(remote, alara:get_cluster_nodes()),
        ?assert(lists:member({PeerNode, up}, Remote1)),
        stop_peer(Peer),
        %% Poll until the monitor processes the nodedown (up to 3 s).
        ok = wait_until(fun() ->
            lists:member({PeerNode, down},
                         maps:get(remote, alara:get_cluster_nodes()))
        end, 3000),
        Bytes = alara:generate_random_bytes(16),
        ?assert(is_binary(Bytes)),
        ?assertEqual(16, byte_size(Bytes))
    after
        teardown_local(),
        catch stop_peer(Peer)   %% tolerant: peer may already be stopped
    end.

%% 20 concurrent callers with one remote peer — all get valid, distinct results.
%% Distinctness is a near-certain safety check (collision prob ≈ 2^-256 per pair).
concurrent_distributed_test() ->
    {Peer, PeerNode} = start_peer(),
    try
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
        ?assertEqual(NumProcs, length(lists:usort(Results)))
    after
        teardown_local(),
        stop_peer(Peer)
    end.

%% Peer connected to distribution but NOT in remote_nodes — must be absent
%% from the cluster view. We start a real peer (not just an atom) to verify
%% that alara ignores connected-but-unconfigured nodes, not merely absent ones.
unconfigured_remote_test() ->
    {Peer, PeerNode} = start_peer(),
    try
        _ = application:stop(alara),
        application:set_env(alara, remote_nodes, []),
        application:set_env(alara, pool_size, ?LOCAL_POOL),
        ok = application:start(alara),
        Remote = maps:get(remote, alara:get_cluster_nodes()),
        ?assertNot(lists:keymember(PeerNode, 1, Remote))
    after
        teardown_local(),
        stop_peer(Peer)
    end.
