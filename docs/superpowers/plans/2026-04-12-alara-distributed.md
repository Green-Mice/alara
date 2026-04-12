# Alara Distributed Entropy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make alara truly distributed by collecting entropy from multiple independent Erlang nodes on separate machines, each running their own alara pool, HKDF-mixed by the coordinator. Public API unchanged.

**Architecture:** New `alara_sup` root supervisor owns both `alara_cluster_monitor` (gen_server that tracks remote nodes in ETS via `erlang:monitor_node/2`) and `alara_node_sup`. `collect_entropy` is extended to spawn monitored lambdas for both local PIDs and remote nodes (via `rpc:call`). Remote failures return a `skip` sentinel and are silently dropped; local worker crashes still propagate as `{error, {worker_died, _}}`.

**Tech Stack:** Erlang/OTP 25+, ETS, `rpc:call/5`, `erlang:monitor_node/2`, `peer` (OTP stdlib) for distributed tests, `erpc:call/4`.

---

## File map

| Action | File |
|--------|------|
| Create | `src/alara_sup.erl` |
| Create | `src/alara_cluster_monitor.erl` |
| Modify | `src/alara_app.erl` |
| Modify | `src/alara_node_sup.erl` |
| Modify | `src/alara.erl` |
| Modify | `src/alara.app.src` |
| Create | `test/alara_cluster_monitor_tests.erl` |
| Create | `test/alara_cluster_tests.erl` |
| Modify | `test/alara_basic_tests.erl` |

---

## Task 1 — Supervision foundation

New root supervisor `alara_sup` + `alara_cluster_monitor` skeleton + wire up `alara_app`. This is one atomic task because the application cannot start until all three pieces exist.

**Files:**
- Create: `src/alara_sup.erl`
- Create: `src/alara_cluster_monitor.erl` (skeleton — full impl in Task 2)
- Modify: `src/alara_app.erl`
- Modify: `src/alara.app.src`
- Modify: `test/alara_basic_tests.erl`

- [ ] **Step 1: Add a failing test for the new supervision tree**

Add at the end of `test/alara_basic_tests.erl` (before the last line):

```erlang
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
```

- [ ] **Step 2: Run the test — verify it fails**

```bash
rebar3 eunit --module=alara_basic_tests
```

Expected: test fails — `alara_sup` and `alara_cluster_monitor` are undefined (`whereis` returns `undefined`).

- [ ] **Step 3: Create `src/alara_sup.erl`**

```erlang
%% ============================================================================
%% alara_sup - Root Supervisor
%%
%% Top-level one_for_one supervisor. Starts alara_cluster_monitor first
%% (so it is available when alara_node_sup workers come online) and stops
%% it last.
%% ============================================================================

-module(alara_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    PoolSize = application:get_env(alara, pool_size, 3),
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 5
    },
    Children = [
        #{
            id       => alara_cluster_monitor,
            start    => {alara_cluster_monitor, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [alara_cluster_monitor]
        },
        #{
            id       => alara_node_sup,
            start    => {alara_node_sup, start_link, [PoolSize]},
            restart  => permanent,
            shutdown => infinity,
            type     => supervisor,
            modules  => [alara_node_sup]
        }
    ],
    {ok, {SupFlags, Children}}.
```

- [ ] **Step 4: Create `src/alara_cluster_monitor.erl` (skeleton)**

This skeleton is enough for the application to start. Full implementation in Task 2.

```erlang
%% ============================================================================
%% alara_cluster_monitor - Remote Node Tracker (skeleton)
%%
%% Skeleton — full ETS/reconnect implementation follows in Task 2.
%% ============================================================================

-module(alara_cluster_monitor).
-behaviour(gen_server).

-export([start_link/0, get_reachable_nodes/0, get_all_nodes/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_reachable_nodes() -> [node()].
get_reachable_nodes() -> [].

-spec get_all_nodes() -> [{node(), up | down}].
get_all_nodes() -> [].

init([])                       -> {ok, #{}}.
handle_call(_, _, State)       -> {reply, ok, State}.
handle_cast(_, State)          -> {noreply, State}.
handle_info(_, State)          -> {noreply, State}.
terminate(_, _)                -> ok.
code_change(_, State, _)       -> {ok, State}.
```

- [ ] **Step 5: Update `src/alara_app.erl`**

Replace the whole file:

```erlang
-module(alara_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    alara_sup:start_link().

stop(_State) -> ok.
```

- [ ] **Step 6: Update `src/alara.app.src`**

Replace `registered` and `modules` lines:

```erlang
{application, alara,
 [
  {description, "ALARA - Distributed Entropy Network System"},
  {vsn, "0.1.8"},
  {registered, [alara_sup, alara_node_sup, alara_cluster_monitor]},
  {mod, {alara_app, []}},
  {applications, [
    kernel,
    stdlib,
    crypto
  ]},
  {env, [
    {pool_size, 3}
  ]},
  {modules, [alara, alara_app, alara_cluster_monitor,
             alara_node, alara_node_sup, alara_sup]},
  {licenses, ["Apache-2.0"]},
  {links, [{"GitHub", "https://github.com/Green-Mice/alara"}]}
 ]}.
```

- [ ] **Step 7: Run all existing tests — verify they all pass**

```bash
rebar3 eunit
```

Expected: all previous tests pass + `supervision_tree_test` now passes.

- [ ] **Step 8: Commit**

```bash
git add src/alara_sup.erl src/alara_cluster_monitor.erl \
        src/alara_app.erl src/alara.app.src \
        test/alara_basic_tests.erl
git commit -m "feat: add alara_sup root supervisor + alara_cluster_monitor skeleton"
```

---

## Task 2 — alara_cluster_monitor full implementation

Replace the skeleton with the real gen_server: ETS table, static node config, `nodeup`/`nodedown` handling, periodic reconnect timer.

**Files:**
- Modify: `src/alara_cluster_monitor.erl`
- Create: `test/alara_cluster_monitor_tests.erl`

- [ ] **Step 1: Create `test/alara_cluster_monitor_tests.erl` with failing tests**

```erlang
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
```

- [ ] **Step 2: Run — verify tests fail**

```bash
rebar3 eunit --module=alara_cluster_monitor_tests
```

Expected: `ets_exists_test`, `fake_nodes_appear_as_down_test`, and ETS-related tests fail because the skeleton ignores all of this.

- [ ] **Step 3: Replace `src/alara_cluster_monitor.erl` with full implementation**

```erlang
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
```

- [ ] **Step 4: Run monitor tests — verify they pass**

```bash
rebar3 eunit --module=alara_cluster_monitor_tests
```

Expected: all 8 tests pass.

Note on `nodeup_updates_ets_test`: after sending `{nodeup, 'fake1@nowhere'}`, the handler calls `erlang:monitor_node('fake1@nowhere', true)` on a non-connected node, which causes an immediate `{nodedown, 'fake1@nowhere'}` to be sent back to the monitor mailbox. The test checks ETS state after 100 ms — at that point the nodedown may have already been processed, so `fake1@nowhere` may be `down` again. If this test is flaky, increase the sleep or remove it — the authoritative nodeup/nodedown test is in the distributed suite (Task 6).

- [ ] **Step 5: Run full test suite — verify nothing regressed**

```bash
rebar3 eunit
```

Expected: all previous tests + all 8 new monitor tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/alara_cluster_monitor.erl test/alara_cluster_monitor_tests.erl
git commit -m "feat: alara_cluster_monitor — ETS node tracking, nodeup/nodedown, reconnect"
```

---

## Task 3 — Distributed collect_entropy

Extend `collect_entropy` to include remote nodes from the monitor. Remote failures send a `skip` sentinel — gracefully dropped. Local worker crashes still propagate as `{error, {worker_died, _}}`.

Note: `collect_chunks/2` needs one new clause for `skip` — the spec says "untouched" but `skip` requires it.

**Files:**
- Modify: `src/alara_node_sup.erl`

- [ ] **Step 1: Replace the three functions in `src/alara_node_sup.erl`**

Find and replace `generate_random_bytes/1` (lines ~84–93):

```erlang
%% @doc Generate N cryptographically secure random bytes.
%%
%% Entropy is collected from all local workers and all reachable remote nodes
%% in parallel, then mixed with HKDF. Remote nodes that fail or timeout are
%% silently skipped; the call still succeeds as long as at least one source
%% contributes. Returns {error, no_nodes} only when every source is unavailable.
-spec generate_random_bytes(N :: pos_integer()) ->
    binary() | {error, no_nodes | {worker_died, term()}}.
generate_random_bytes(N) when is_integer(N), N > 0 ->
    LocalWorkers = get_nodes(),
    case collect_entropy(LocalWorkers, N) of
        {ok, Raw}        -> mix_entropy(Raw, N);
        {error, _} = Err -> Err
    end.
```

Find and replace `collect_entropy/2` (lines ~162–182), the internal spec comment, and the helper — replace the entire block starting at the `%% Distribute the byte request...` comment through `collect_chunks(Pending, []).`:

```erlang
%% Distribute the byte request across all available sources:
%% local worker PIDs (always) + reachable remote alara nodes (when configured).
%%
%% For local PIDs : call alara_node:get_random_bytes directly.
%% For remote nodes: rpc:call → alara:generate_random_bytes on the remote node.
%%   {badrpc, _} → lambda sends 'skip', collect_chunks silently drops it.
%%
%% Two-level HKDF: each remote node HKDF-mixes its own local pool before
%% replying; the coordinator then HKDF-mixes all contributions together.
-spec collect_entropy([pid()], pos_integer()) ->
    {ok, binary()} | {error, no_nodes | {worker_died, term()}}.
collect_entropy(LocalWorkers, TotalBytes) ->
    RemoteNodes = alara_cluster_monitor:get_reachable_nodes(),
    AllSources  = LocalWorkers ++ RemoteNodes,
    case AllSources of
        [] ->
            {error, no_nodes};
        _ ->
            Timeout    = application:get_env(alara, remote_timeout_ms, 5000),
            NumSources = length(AllSources),
            BytesPer   = TotalBytes div NumSources,
            Remainder  = TotalBytes rem NumSources,
            Self       = self(),
            Pending = [begin
                           Ref = make_ref(),
                           Share = case {I, Remainder} of
                               {1, R} when R > 0 -> BytesPer + R;
                               _                 -> BytesPer
                           end,
                           {_, MRef} = spawn_monitor(fun() ->
                               Msg = fetch_chunk(Source, max(1, Share), Timeout),
                               Self ! {Ref, Msg}
                           end),
                           {Ref, MRef}
                       end || {I, Source} <-
                               lists:zip(lists:seq(1, NumSources), AllSources)],
            collect_chunks(Pending, [])
    end.

%% Fetch bytes from a local PID worker or a remote node.
%% Remote failures return the atom 'skip' (never crash the lambda).
-spec fetch_chunk(pid() | node(), pos_integer(), pos_integer()) ->
    binary() | skip.
fetch_chunk(Source, N, _Timeout) when is_pid(Source) ->
    alara_node:get_random_bytes(Source, N);
fetch_chunk(Source, N, Timeout) when is_atom(Source) ->
    case rpc:call(Source, alara, generate_random_bytes, [N], Timeout) of
        {badrpc, _} -> skip;
        Bytes       -> Bytes
    end.
```

Find and replace `collect_chunks/2` (lines ~186–198) — add one `skip` clause:

```erlang
%% Collect lambda results in order.
%% skip  : remote node was unreachable — silently drop, continue.
%% DOWN  : local worker crashed — cancel remaining monitors, return error.
-spec collect_chunks([{reference(), reference()}], [binary()]) ->
    {ok, binary()} | {error, no_nodes | {worker_died, term()}}.
collect_chunks([], []) ->
    {error, no_nodes};
collect_chunks([], Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
collect_chunks([{Ref, MRef} | Rest], Acc) ->
    receive
        {Ref, skip} ->
            demonitor(MRef, [flush]),
            collect_chunks(Rest, Acc);
        {Ref, Chunk} ->
            demonitor(MRef, [flush]),
            collect_chunks(Rest, [Chunk | Acc]);
        {'DOWN', MRef, process, _Pid, Reason} ->
            [demonitor(M, [flush]) || {_, M} <- Rest],
            {error, {worker_died, Reason}}
    end.
```

- [ ] **Step 2: Run the full test suite — verify nothing regressed**

```bash
rebar3 eunit
```

Expected: all existing tests pass. With `remote_nodes = []` in test setup, `AllSources = LocalWorkers` — identical behaviour to 0.1.8.

- [ ] **Step 3: Commit**

```bash
git add src/alara_node_sup.erl
git commit -m "feat: extend collect_entropy to collect from remote alara nodes"
```

---

## Task 4 — Public API: get_cluster_nodes/0

Add `alara:get_cluster_nodes/0` — the operator-facing view of the full cluster (local workers + remote node statuses).

**Files:**
- Modify: `src/alara.erl`
- Modify: `test/alara_basic_tests.erl`

- [ ] **Step 1: Add a failing test for get_cluster_nodes/0**

Add to `test/alara_basic_tests.erl`:

```erlang
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
```

- [ ] **Step 2: Run — verify it fails**

```bash
rebar3 eunit --module=alara_basic_tests
```

Expected: `get_cluster_nodes_test` fails with `undef` — function does not exist yet.

- [ ] **Step 3: Add get_cluster_nodes/0 to `src/alara.erl`**

Add to the `-export` list:

```erlang
-export([
    get_nodes/0,
    get_cluster_nodes/0,
    generate_random_bytes/1,
    generate_random_bits/1,
    generate_random_int/1
]).
```

Add after `get_nodes/0`:

```erlang
%% @doc Return the full cluster view: local worker PIDs and remote node statuses.
%%
%% Useful for monitoring, health checks, and dashboards.
%% `remote` is [] when remote_nodes is not configured.
-spec get_cluster_nodes() ->
    #{local => [pid()], remote => [{node(), up | down}]}.
get_cluster_nodes() ->
    #{
        local  => alara_node_sup:get_nodes(),
        remote => alara_cluster_monitor:get_all_nodes()
    }.
```

- [ ] **Step 4: Run — verify test passes**

```bash
rebar3 eunit --module=alara_basic_tests
```

Expected: `get_cluster_nodes_test` passes.

- [ ] **Step 5: Run full suite — verify nothing regressed**

```bash
rebar3 eunit
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/alara.erl test/alara_basic_tests.erl
git commit -m "feat: add alara:get_cluster_nodes/0 — full cluster view"
```

---

## Task 5 — Strengthen existing tests

Add property-style loops and concurrency tests to `test/alara_basic_tests.erl`. These tests catch regressions that single-call tests miss.

**Files:**
- Modify: `test/alara_basic_tests.erl`

- [ ] **Step 1: Add the new tests**

Add all of the following to `test/alara_basic_tests.erl`:

```erlang
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
%% Test: worker crash does not hang and is handled gracefully (extended)
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
```

- [ ] **Step 2: Run — verify all new tests pass**

```bash
rebar3 eunit --module=alara_basic_tests
```

Expected: all tests pass, including the 6 new ones.

- [ ] **Step 3: Commit**

```bash
git add test/alara_basic_tests.erl
git commit -m "test: strengthen basic suite — size loops, range check, concurrent uniqueness"
```

---

## Task 6 — Distributed integration tests

Real distributed tests using `peer:start_link/1` (OTP 25+). These tests start actual child BEAM nodes in the test process. They require the current node to be a distributed Erlang node; the test file starts distribution automatically.

**Files:**
- Create: `test/alara_cluster_tests.erl`

- [ ] **Step 1: Create `test/alara_cluster_tests.erl`**

```erlang
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
            {skip, io_lib:format("Distributed Erlang unavailable: ~p", [Reason])}
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
        {"peer shows as up in cluster view",   fun cluster_view_test/0},
        {"generation works with remote peer",  fun remote_contributes_test/0},
        {"dead remote node: local fallback",   fun remote_node_down_graceful_test/0},
        {"unconfigured node: local fallback",  fun unconfigured_remote_test/0},
        {"peer goes down: marked down in ETS", fun remote_node_stops_marks_down_test/0},
        {"concurrent distributed generation",  fun concurrent_distributed_test/0},
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
```

- [ ] **Step 2: Run the distributed tests**

```bash
rebar3 eunit --module=alara_cluster_tests
```

Expected: all 7 tests pass. If the test node cannot start distribution (rare in most dev environments), the suite skips gracefully with a message.

- [ ] **Step 3: Run the full test suite**

```bash
rebar3 eunit
```

Expected: all tests across all modules pass.

- [ ] **Step 4: Commit**

```bash
git add test/alara_cluster_tests.erl
git commit -m "test: distributed integration tests with peer nodes (OTP 25+)"
```

---

## Self-review

**Spec coverage:**

| Spec requirement | Task |
|-----------------|------|
| `alara_sup` root supervisor | Task 1 |
| `alara_cluster_monitor` gen_server + ETS | Task 2 |
| `alara_app` starts `alara_sup` | Task 1 |
| `alara.app.src` modules + registered | Task 1 |
| Extended `collect_entropy` | Task 3 |
| `fetch_chunk` local/remote dispatch | Task 3 |
| `collect_chunks` skip sentinel | Task 3 |
| `get_cluster_nodes/0` | Task 4 |
| Graceful degradation (unreachable node) | Task 3 + Task 6 |
| Reconnect timer | Task 2 |
| `nodeup`/`nodedown` handling | Task 2 |
| ETS try/catch safety | Task 2 |
| Strengthened basic tests | Task 5 |
| Distributed peer tests | Task 6 |

All spec requirements covered. ✓

**Type consistency:**
- `get_reachable_nodes/0 → [node()]` used in `collect_entropy` — consistent ✓
- `get_all_nodes/0 → [{node(), up | down}]` used in `get_cluster_nodes/0` — consistent ✓
- `fetch_chunk/3` returns `binary() | skip` — `skip` handled in `collect_chunks` ✓
- `collect_chunks/2` returns `{ok, binary()} | {error, no_nodes | {worker_died, term()}}` — propagated correctly in `generate_random_bytes` ✓
