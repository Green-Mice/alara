# ALARA - Distributed Entropy System

**ALARA** is a lightweight distributed entropy system written in Erlang.  
It spawns multiple supervised nodes capable of generating random bits and integers in a distributed fashion.

[![Hex.pm](https://img.shields.io/hexpm/v/alara.svg)](https://hex.pm/packages/alara)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/alara)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

## Features

- **Distributed Randomness**: Generate random booleans and integers across multiple Erlang nodes  
- **Node Supervision**: Automatic node management via Erlang supervisors  
- **Scalable Network Creation**: Easily create networks with configurable node counts  
- **Simple API**: Small, clean, and efficient interface for distributed randomness

## Requirements

- Erlang/OTP 25+
- Rebar3

## Quick Start

### 1. Clone and Build

```bash
git clone https://github.com/Green-Mice/alara.git
cd alara
rebar3 compile
```

### 2. Run the Erlang Shell

```bash
rebar3 shell
```

### 3. Basic Usage Example

```erlang
%% Create a network with 3 nodes
{ok, NetPid} = alara:create_network().

%% Or create a network with N nodes
{ok, NetPid} = alara:create_network(5).

%% Retrieve all node PIDs
{ok, Nodes} = alara:get_nodes(NetPid),
io:format("Nodes: ~p~n", [Nodes]).

%% Generate 16 distributed random booleans
Bits = alara:generate_random_bools(16),
io:format("Bits: ~p~n", [Bits]).

%% Generate a random integer from 32 bits of distributed randomness
RandInt = alara:generate_random_int(32),
io:format("Random Int: ~p~n", [RandInt]).
```

## API Reference

### Network Management
- `alara:create_network/0` – Create a network with 3 nodes  
- `alara:create_network/1` – Create a network with a given number of nodes  
- `alara:get_network_state/1` – Get the internal network state (node supervisor, node list)  
- `alara:get_nodes/1` – Get the list of node PIDs in the network  

### Random Generation
- `alara:generate_random_bools/1` – Generate N random booleans distributed across all nodes  
- `alara:generate_random_bools/2` – Generate N random booleans from a specific node  
- `alara:generate_random_int/1` – Generate a random integer from N distributed bits  

## Architecture

ALARA uses a simple distributed design:
- **`alara_node_sup`** supervises all random node processes.  
- **`alara_node`** represents a random entropy source.  
- **`alara`** coordinates network creation, node access, and random generation requests.

All randomness is generated using Erlang’s `rand` module, distributed across worker nodes managed by a supervisor.

## License

Apache 2.0

---

*ALARA provides a minimal yet powerful framework for distributed randomness generation in Erlang.*

