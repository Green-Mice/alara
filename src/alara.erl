%% ============================================================================
%% alara - Distributed Entropy Network System
%%
%% ALARA is an OTP application that provides cryptographically secure
%% randomness by aggregating entropy from a supervised pool of worker nodes.
%% All output bytes pass through a SHA3-256 mixing step before being
%% returned to callers (for requests up to 32 bytes).
%%
%% Architecture
%% ------------
%%
%%   alara_app (application callback)
%%     └── alara_node_sup (supervisor)
%%           ├── alara_node  (entropy worker)
%%           ├── alara_node  (entropy worker)
%%           └── ...
%%
%% Quick start
%% -----------
%%
%%   %% In your .app.src deps or sys.config:
%%   [{alara, [{pool_size, 5}]}]
%%
%%   %% Then simply:
%%   Bytes = alara:generate_random_bytes(32),
%%   Bits  = alara:generate_random_bits(256),
%%   Int   = alara:generate_random_int(128),
%%   Nodes   = alara:get_cluster_nodes(),   % full view: local PIDs + remote statuses
%%
%% Security requirements
%% ---------------------
%% - Erlang distribution MUST be secured with TLS when running across
%%   physical or virtual machines (`-proto_dist inet_tls`).
%% - The Erlang cookie MUST be a high-entropy secret.
%% - This library has NOT been formally audited by an independent
%%   cryptographer. Treat it as experimental for high-security
%%   production use until such an audit is completed.
%%
%% ============================================================================

-module(alara).

-export([
    get_nodes/0,
    get_cluster_nodes/0,
    generate_random_bytes/1,
    generate_random_bits/1,
    generate_random_int/1
]).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

%% @doc Return the PIDs of all currently live entropy workers.
-spec get_nodes() -> [pid()].
get_nodes() ->
    alara_node_sup:get_nodes().

%% @doc Return the full cluster view: local worker PIDs and remote node statuses.
%%
%% Useful for monitoring, health checks, and dashboards.
%% Returns `#{local => [...], remote => []}` when remote_nodes is not configured.
-spec get_cluster_nodes() ->
    #{local => [pid()], remote => [{node(), up | down}]}.
get_cluster_nodes() ->
    #{
        local  => alara_node_sup:get_nodes(),
        remote => alara_cluster_monitor:get_all_nodes()
    }.

%% @doc Generate N cryptographically secure random bytes.
%%
%% Entropy is collected from all workers in parallel and mixed with
%% SHA3-256 before being returned. See alara_node_sup for the full
%% mixing strategy.
%%
%% Returns {error, no_nodes} if the pool has no live workers.
-spec generate_random_bytes(N :: pos_integer()) ->
    binary() | {error, no_nodes}.
generate_random_bytes(N) when is_integer(N), N > 0 ->
    alara_node_sup:generate_random_bytes(N).

%% @doc Generate N random bits as a list of 0 | 1 integers.
-spec generate_random_bits(N :: pos_integer()) ->
    [0 | 1] | {error, no_nodes}.
generate_random_bits(N) when is_integer(N), N > 0 ->
    alara_node_sup:generate_random_bits(N).

%% @doc Generate a non-negative random integer using NBits of entropy.
%%
%% The result is in the range [0, 2^NBits - 1].
-spec generate_random_int(NBits :: pos_integer()) ->
    non_neg_integer() | {error, no_nodes}.
generate_random_int(NBits) when is_integer(NBits), NBits > 0 ->
    alara_node_sup:generate_random_int(NBits).
