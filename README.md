# ALARA - Distributed Entropy Network System

**ALARA** is a distributed entropy network system implemented in Erlang. It enables you to create a network of nodes, inject entropy, and manage distributed randomness across multiple participants in a decentralized manner.

## Features

- **Distributed Network Management**: Create and manage distributed entropy networks with multiple nodes
- **Node Trust System**: Add and remove nodes with configurable trust levels
- **Entropy Injection & Propagation**: Inject entropy from any node and propagate it across the network
- **Network Quality Monitoring**: Query network quality metrics and consensus status
- **Decentralized Randomness**: Generate and maintain a global entropy pool from distributed sources

## Requirements

- Erlang/OTP 25+ 
- Rebar3

## Quick Start

### 1. Clone and Build

```bash
git clone https://github.com/roquess/alara.git
cd alara
rebar3 compile
```

### 2. Run the Erlang Shell

```bash
rebar3 shell
```

### 3. Basic Usage Example

```erlang
% Create a new distributed entropy network
{ok, NetPid} = alara:create_network().

% Create a node with ID 1, trust level 0.9, and mark it as active
{ok, Node} = alara:create_node(1, 0.9, true).

% Add the node to the network
{ok, node_added} = alara:add_node(NetPid, Node).

% Generate 32 random bits
Bits = [rand:uniform(2) =:= 1 || _ <- lists:seq(1, 32)].

% Inject entropy into the network from node 1
ok = alara:generate_entropy(NetPid, {1, Bits}).

% (Optional) Wait a moment for the entropy to be processed
timer:sleep(100).

% Retrieve the global entropy pool
{ok, Network} = gen_server:call(NetPid, get_network_state),
Pool = Network#distributed_entropy_network.global_entropy_pool.

% Check that your bits are in the pool
io:format("First 32 bits in pool: ~p~n", [lists:sublist(Pool, 32)]).
```

## API Reference

### Network Management

- `alara:create_network/0` - Create a new distributed entropy network
- `alara:add_node/2` - Add a node to the network
- `alara:remove_node/2` - Remove a node from the network

### Node Operations

- `alara:create_node/3` - Create a new node with ID, trust level, and active status
- `alara:generate_entropy/2` - Inject entropy from a specific node

### Network Monitoring

- `gen_server:call(NetPid, get_network_state)` - Get current network state
- Query network quality and consensus metrics

## Architecture

ALARA uses a distributed architecture where:

- **Nodes** represent entropy sources with configurable trust levels
- **Networks** manage collections of nodes and maintain global entropy pools
- **Entropy** is propagated across the network using Erlang's distributed capabilities
- **Trust levels** influence how entropy from different nodes is weighted

## Use Cases

- Distributed random number generation
- Cryptographic key material generation
- Consensus randomness for blockchain applications
- Multi-party computation requiring shared randomness

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

## License

Apache 2.0

---

*ALARA provides a robust foundation for distributed entropy management in Erlang applications requiring decentralized randomness.*
