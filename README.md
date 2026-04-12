# ALARA — Distributed Entropy Network System

**ALARA** is a lightweight distributed entropy system written in Erlang/OTP.  
It supervises a pool of worker nodes, each producing cryptographically secure
random bytes via `crypto:strong_rand_bytes/1`. Contributions from all workers
are mixed with **HKDF (RFC 5869, SHA3-256)** before being returned, so the
output remains unpredictable even if all but one worker is compromised — for
any requested output size.

[![Hex.pm](https://img.shields.io/hexpm/v/alara.svg)](https://hex.pm/packages/alara)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/alara)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

---

## Features

- **Cryptographically secure** — built exclusively on `crypto:strong_rand_bytes/1` (OTP `crypto` application), never on `rand`
- **HKDF mixing** — all worker contributions are combined via HKDF-Extract + HKDF-Expand (RFC 5869, SHA3-256); the security guarantee holds for any output size
- **Multi-machine distribution** — entropy is collected from independent remote alara nodes via RPC; each remote node HKDF-mixes its own pool, then the coordinator mixes all contributions
- **Graceful degradation** — unreachable remote nodes are skipped transparently; output is always produced as long as at least one source (local or remote) is alive
- **OTP-supervised pool** — workers restart automatically on failure; the node list is always read live from the supervisor
- **Crash-resilient collection** — each worker request is monitored; if a worker dies mid-collection the call returns `{error, {worker_died, Reason}}` immediately instead of hanging
- **Parallel collection** — worker requests (local and remote) are issued concurrently to minimise latency
- **Clean, minimal API** — bytes, bits, or integers; one call each

---

## Requirements

- Erlang/OTP 25+
- Rebar3

> **Security note — distributed Erlang**  
> When running ALARA across multiple machines or VMs, secure the Erlang
> distribution channel with TLS (`-proto_dist inet_tls`) and use a
> high-entropy cookie. Without TLS, a network attacker can observe or
> interfere with inter-node traffic.  
> This library has not yet been formally audited by an independent
> cryptographer. Treat it as experimental for high-security production
> environments until such an audit is completed.

---

## Quick Start

### 1. Add to your project

```erlang
%% rebar.config
{deps, [{alara, "0.1.8"}]}.
```

### 2. Build

```bash
git clone https://github.com/Green-Mice/alara.git
cd alara
rebar3 compile
```

### 3. Run the shell

```bash
rebar3 shell
```

### 4. Basic usage

```erlang
%% alara starts automatically with your application (pool_size defaults to 3).
%% Configure via sys.config if needed:
%%   [{alara, [{pool_size, 5}]}]

%% List the live worker PIDs.
Nodes = alara:get_nodes(),
io:format("Workers: ~p~n", [Nodes]).

%% Generate 32 cryptographically secure random bytes.
Bytes = alara:generate_random_bytes(32),
io:format("Bytes: ~p~n", [Bytes]).

%% Generate 64 random bits as a list of 0 | 1 integers.
Bits = alara:generate_random_bits(64),
io:format("Bits: ~p~n", [Bits]).

%% Generate a random non-negative integer using 128 bits of entropy.
%% Result is in [0, 2^128 - 1].
Int = alara:generate_random_int(128),
io:format("Int: ~p~n", [Int]).
```

### 5. Distributed usage (optional)

Configure remote alara nodes in your `sys.config`:

```erlang
[{alara, [
    {pool_size,        3},
    {remote_nodes,     ['alara@host1', 'alara@host2']},
    {remote_timeout_ms, 5000}
]}].
```

Each remote node must be running the alara application. Entropy is collected
from all reachable nodes in parallel and HKDF-mixed on the coordinator.
Unreachable nodes are skipped automatically — the call never fails as long as
at least one source is alive.

```erlang
%% Full cluster view: local PIDs + remote node statuses.
#{local := LocalPids, remote := RemoteStatuses} = alara:get_cluster_nodes(),
io:format("Local workers: ~p~n", [LocalPids]),
io:format("Remote nodes:  ~p~n", [RemoteStatuses]).
%% => Remote nodes: [{'alara@host1', up}, {'alara@host2', down}]
```

---

## API Reference

### Pool management

| Function | Description |
|---|---|
| `alara:get_nodes/0` | Return the PIDs of all currently live local workers |
| `alara:get_cluster_nodes/0` | Return `#{local => [pid()], remote => [{node(), up\|down}]}` |
| `alara_node_sup:add_node/0` | Dynamically add a worker to the running pool |

### Entropy generation

| Function | Returns | Description |
|---|---|---|
| `alara:generate_random_bytes/1` | `binary() \| {error, ...}` | `N` random bytes, HKDF mixed |
| `alara:generate_random_bits/1` | `[0\|1]` | `N` random bits |
| `alara:generate_random_int/1` | `non_neg_integer()` | Random integer in `[0, 2^N - 1]` |

### Direct worker access

```erlang
%% Start a standalone worker (no supervisor).
{ok, Pid} = alara_node:start_link().

%% Request raw bytes directly from one worker (no mixing step).
Bytes = alara_node:get_random_bytes(Pid, 16).
```

---

## Architecture

```
alara_app  (application callback)
  └── alara_sup  (one_for_one, root supervisor)
        ├── alara_cluster_monitor  (gen_server — remote node tracker)
        └── alara_node_sup         (supervisor, one_for_one)
              ├── alara_node  (entropy worker — crypto:strong_rand_bytes)
              ├── alara_node  (entropy worker — crypto:strong_rand_bytes)
              └── ...
```

**`alara_node`** — each worker holds no mutable state. On every request it
calls `crypto:strong_rand_bytes/1` and returns the result. There is nothing
to compromise at rest.

**`alara_node_sup`** — supervises the local worker pool. When generating
entropy, it queries `alara_cluster_monitor` for reachable remote nodes and
dispatches requests to local workers and remote nodes in parallel. Remote
results arrive via `rpc:call/5`; a `{badrpc, _}` response skips that node
silently. Contributions are mixed with HKDF-Extract + HKDF-Expand (RFC 5869,
SHA3-256), preserving the security guarantee for any output size.

**`alara_cluster_monitor`** — gen_server that maintains a live ETS view of
configured remote nodes (`{node(), up | down}`). Uses `erlang:monitor_node/2`
for instant `nodedown` notifications and a periodic reconnect timer (10 s) to
recover nodes that were down at startup. The ETS table is public so
`collect_entropy` can read it without a message hop.

**`alara`** — thin API module. Delegates to `alara_node_sup` with no extra
message hop.

---

## Running Tests

```bash
rebar3 eunit
```

---

## License

Apache 2.0
