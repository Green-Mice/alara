%% ============================================================================
%% alara.hrl - Shared record and type definitions for the ALARA ecosystem
%% ============================================================================

%% State of the top-level ALARA gen_server.
%% - node_supervisor : PID of the alara_node_sup supervisor
-record(state, {
    node_supervisor :: pid()
}).

%% Internal state of a single entropy node.
%% Intentionally minimal: the node holds no mutable data,
%% all randomness is produced on demand via crypto(3).
-record(node_state, {}).
