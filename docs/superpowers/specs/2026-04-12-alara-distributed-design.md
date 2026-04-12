# Alara Distributed Entropy — Design Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make alara truly distributed — entropy is collected from multiple independent Erlang nodes on separate machines, each running their own alara pool, and HKDF-mixed locally. The public API is 100% unchanged.

**Architecture:** A new top-level supervisor (`alara_sup`) owns both a `alara_cluster_monitor` gen_server and the existing `alara_node_sup`. The monitor maintains a live ETS view of which remote nodes are reachable. `collect_entropy` in `alara_node_sup` extends to collect from remote nodes via `rpc:call` in parallel alongside local workers.

**Tech stack:** Erlang/OTP 25+, `peer` module for distributed tests, `erlang:monitor_node/2`, ETS, `rpc:call/5`.

---

## Constraints

- `alara:generate_random_bytes/1`, `generate_random_bits/1`, `generate_random_int/1`, `get_nodes/0` — signatures and return types **unchanged**. keylara and alara_uuid must require zero changes.
- `remote_nodes` absent or `[]` in config → identical behaviour to 0.1.8, zero overhead.
- Graceful degradation: if a remote node is unreachable, skip it and continue with available sources. Always return a result as long as at least one source (local or remote) is alive.
- Static node list only (no dynamic discovery in this version). Architecture is designed so the monitor's node source can be replaced later.
- Target: OTP 25+ (`peer` module available).

---

## Files

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `src/alara_sup.erl` | Top-level `one_for_one` supervisor; starts `alara_cluster_monitor` then `alara_node_sup` |
| Create | `src/alara_cluster_monitor.erl` | gen_server; tracks reachable remote nodes in ETS; handles nodeup/nodedown/reconnect |
| Modify | `src/alara_app.erl` | Start `alara_sup` instead of `alara_node_sup` directly |
| Modify | `src/alara_node_sup.erl` | Extend `collect_entropy` to include remote nodes |
| Modify | `src/alara.erl` | Add `get_cluster_nodes/0` |
| Modify | `src/alara.app.src` | Add new modules to `modules`; add `alara_cluster_monitor` to `registered` |
| Create | `test/alara_cluster_tests.erl` | Distributed tests using `peer:start_link/1` |
| Modify | `test/alara_basic_tests.erl` | Strengthen existing tests (see test plan) |

---

## Configuration

```erlang
%% sys.config or application:set_env/3
{alara, [
    {pool_size,        3},        %% existing — local worker count
    {remote_nodes,     []},       %% NEW — list of remote node atoms, e.g. ['a@host1', 'b@host2']
    {remote_timeout_ms, 5000}     %% NEW — per-node RPC timeout in ms (default 5000)
]}
```

---

## Supervision tree

```
alara_app
  └── alara_sup  (one_for_one)
        ├── alara_cluster_monitor  (permanent, worker)
        └── alara_node_sup         (permanent, supervisor)
              ├── alara_node
              ├── alara_node
              └── ...
```

`alara_cluster_monitor` is listed first so it is started before `alara_node_sup` and stopped after it.

---

## `alara_cluster_monitor` — behaviour

### ETS table

Name: `alara_cluster_nodes`  
Schema: `{node(), up | down}`  
Access: `public`, `set` — readable by any process without a message (no bottleneck under concurrency).

### Init sequence

For each node in `remote_nodes`:
1. Attempt `net_kernel:connect_node(Node)`.
2. Success → insert `{Node, up}`, call `erlang:monitor_node(Node, true)`.
3. Failure → insert `{Node, down}`.
4. Schedule periodic reconnect timer (default interval: 10 s, not configurable in this version — YAGNI).

### Message handling

| Message | Action |
|---------|--------|
| `{nodeup, Node}` | ETS `{Node, up}`, `erlang:monitor_node(Node, true)` |
| `{nodedown, Node}` | ETS `{Node, down}` |
| `reconnect_tick` | For each `down` node: attempt `net_kernel:connect_node`; if ok → `{nodeup, Node}` path. Reschedule timer. |

### Public API

```erlang
%% Returns nodes currently marked `up` in ETS. Zero-copy read.
%% Returns [] if the ETS table does not exist yet (monitor restarting).
-spec get_reachable_nodes() -> [node()].

%% Returns all configured nodes with their status.
%% Returns [] if the ETS table does not exist yet (monitor restarting).
-spec get_all_nodes() -> [{node(), up | down}].
```

Both functions must wrap the ETS read in a `try/catch` and return `[]` on `badarg` — this makes `collect_entropy` degrade gracefully to local-only if the monitor is temporarily restarting under `one_for_one`.

---

## `collect_entropy` — distributed extension

```
collect_entropy(TotalBytes)
  │
  ├── LocalWorkers  = alara_node_sup:get_nodes()
  ├── RemoteNodes   = alara_cluster_monitor:get_reachable_nodes()
  ├── AllSources    = LocalWorkers ++ RemoteNodes   %% mixed list of pid() | node()
  │
  ├── For each source, discriminate by is_pid(S):
  │     pid()  → spawn_monitor, call alara_node:get_random_bytes(Pid, Share)
  │     node() → spawn_monitor, rpc:call(Node, alara, generate_random_bytes, [Share], Timeout)
  │               {badrpc, _} → lambda exits normally, DOWN fires, collect_chunks skips it
  │
  └── collect_chunks/2 — unchanged
```

**Share distribution:** `TotalBytes` divided equally across `length(AllSources)` sources; remainder assigned to the first source (existing logic, unchanged).

**Two-level HKDF:** each remote node runs `alara:generate_random_bytes/1` on its own pool (HKDF-mixed locally). The coordinator then HKDF-mixes all contributions. Security guarantee: output is unpredictable as long as any single source — local or remote — is honest.

**Edge cases:**
- `remote_nodes = []` → `AllSources = LocalWorkers`, identical to 0.1.8.
- Remote node reachable in ETS but drops before reply → `{badrpc, _}` or process DOWN → skipped, local workers provide the output.
- All remote nodes down → local pool only, always returns bytes (never `{error, no_nodes}` unless local pool is also empty).

---

## `alara:get_cluster_nodes/0`

```erlang
-spec get_cluster_nodes() ->
    #{local => [pid()], remote => [{node(), up | down}]}.
get_cluster_nodes() ->
    #{
        local  => alara_node_sup:get_nodes(),
        remote => alara_cluster_monitor:get_all_nodes()
    }.
```

Returns `#{local => [...], remote => []}` when `remote_nodes` is not configured.

---

## Test plan

### Strengthened existing tests (`alara_basic_tests.erl`)

The existing suite covers the happy path well. Add:

| Test | What it verifies |
|------|-----------------|
| `no_nodes_error_test` | Kill all workers, call `generate_random_bytes/1`, assert `{error, no_nodes}` |
| `add_node_increases_pool_test` | Call `alara_node_sup:add_node/0`, assert `length(get_nodes())` increases by 1 |
| `generate_bytes_correct_size_loop_test` | Generate bytes for sizes 1..64, assert `byte_size` matches each time |
| `generate_int_range_test` | 1000 iterations of `generate_random_int(8)`, assert all in `[0, 255]` |
| `bits_all_zero_or_one_test` | 1000 bits, assert every element is `0` or `1` (already exists but make it a property loop) |
| `concurrent_no_duplicates_test` | 50 concurrent callers × 32 bytes each, assert all results are distinct |

### New distributed tests (`alara_cluster_tests.erl`)

Uses `peer:start_link/1` (OTP 25+) to start real child BEAM nodes in the test process.

```erlang
%% Fixture: start a peer node running alara, tear it down after.
peer_setup() ->
    {ok, Peer, PeerNode} = peer:start_link(#{
        name => alara_peer,
        args => ["-pa", code:lib_dir(alara, ebin)]
    }),
    ok = erpc:call(PeerNode, application, ensure_all_started, [alara]),
    {Peer, PeerNode}.

peer_cleanup({Peer, _PeerNode}) ->
    peer:stop(Peer).
```

| Test | What it verifies |
|------|-----------------|
| `remote_contributes_test` | Configure local alara with `remote_nodes = [PeerNode]`; generate 32 bytes; assert result is a valid 32-byte binary |
| `remote_entropy_differs_from_local_test` | Generate bytes with remote node, then stop the remote and generate again (local only); assert the two results differ (probabilistic — collision prob ≈ 2^-256) |
| `remote_node_down_graceful_test` | Configure a non-existent node in `remote_nodes`; assert `generate_random_bytes/1` still returns a valid binary (local fallback) |
| `remote_node_reconnects_test` | Start peer, generate bytes (remote contributes). Stop peer. Generate bytes (local only — valid). Restart peer. Wait for reconnect tick. Generate bytes again. Assert `get_cluster_nodes()` shows `up` for the peer. |
| `cluster_view_test` | With one peer up and one fake node configured; assert `get_cluster_nodes()` returns `#{local => [_|_], remote => [{PeerNode, up}, {FakeNode, down}]}` |
| `empty_remote_nodes_test` | No `remote_nodes` config; assert `get_cluster_nodes()` returns `#{local => [_|_], remote => []}` and generation works normally |
| `concurrent_distributed_test` | 20 concurrent processes each generating 32 bytes with one remote peer; assert all results are valid 32-byte binaries and all distinct |

---

## What does NOT change

- `alara_node.erl` — untouched
- `alara.hrl` — untouched
- `alara:get_nodes/0` — returns local PIDs only, unchanged
- keylara, alara_uuid — zero changes required
- HKDF implementation — untouched
- `collect_chunks/2` — untouched

---

## Out of scope (future)

- Dynamic node discovery (nodes auto-join when they connect to the cluster)
- Per-node weight configuration (some nodes contribute more bytes than others)
- Telemetry / metrics (node contribution counts, latency per node)
- Backoff on reconnect attempts
