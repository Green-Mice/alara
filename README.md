# ALARA — Distributed Entropy Network System

**ALARA** is a lightweight distributed entropy system written in Erlang/OTP.  
It supervises a pool of worker nodes, each producing cryptographically secure
random bytes via `crypto:strong_rand_bytes/1`. Contributions from all workers
are mixed with **SHA3-256** before being returned, so the output remains
unpredictable even if all but one worker is compromised.

[![Hex.pm](https://img.shields.io/hexpm/v/alara.svg)](https://hex.pm/packages/alara)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/alara)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

---

## Features

- **Cryptographically secure** — built exclusively on `crypto:strong_rand_bytes/1` (OTP `crypto` application), never on `rand`
- **Distributed mixing** — entropy from every worker is combined and hashed with SHA3-256 before use
- **OTP-supervised pool** — workers restart automatically on failure; the node list is always read live from the supervisor
- **Parallel collection** — worker requests are issued concurrently to minimise latency
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
{deps, [{alara, "0.1.6"}]}.
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
%% Start a pool of 5 entropy workers.
{ok, NetPid} = alara:create_network(5).

%% Or use the default (3 workers).
{ok, NetPid} = alara:create_network().

%% List the live worker PIDs.
{ok, Nodes} = alara:get_nodes(NetPid),
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

---

## API Reference

### Network management

| Function | Description |
|---|---|
| `alara:create_network/0` | Start a supervised pool with 3 entropy workers |
| `alara:create_network/1` | Start a supervised pool with `N` entropy workers |
| `alara:get_nodes/1` | Return the PIDs of all currently live workers |

### Entropy generation

All functions below are also available directly on `alara_node_sup` for a
lighter call path (no extra `gen_server` hop).

| Function | Returns | Description |
|---|---|---|
| `alara:generate_random_bytes/1` | `binary()` | `N` random bytes, SHA3-256 mixed |
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
alara  (gen_server — optional façade)
  └── alara_node_sup  (supervisor, one_for_one)
        ├── alara_node  (entropy worker — crypto:strong_rand_bytes)
        ├── alara_node  (entropy worker — crypto:strong_rand_bytes)
        └── ...
```

**`alara_node`** — each worker holds no mutable state. On every request it
calls `crypto:strong_rand_bytes/1` and returns the result. There is nothing
to compromise at rest.

**`alara_node_sup`** — supervises the worker pool (`one_for_one`, permanent
restart). Worker requests are issued in parallel; results are concatenated
and hashed with SHA3-256. The node list is always fetched live from
`supervisor:which_children/1` — never from a stale cache.

**`alara`** — thin gen_server façade. Starts the supervisor and re-exports
the generation functions. Generation calls delegate directly to
`alara_node_sup`, adding no extra message hop.

---

## Running Tests

```bash
rebar3 eunit
```

---

## License

Apache 2.0
