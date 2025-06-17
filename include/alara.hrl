-ifndef(ALARA_HRL).
-define(ALARA_HRL, true).

-record(entropy_source, {
    source_id :: non_neg_integer(),
    entropy_data :: [boolean()],
    quality_metric :: float(),
    timestamp :: non_neg_integer(),
    physical_signature :: [float()]
}).

-record(node, {
    node_id :: non_neg_integer(),
    sources :: [#entropy_source{}],
    neighbors :: [non_neg_integer()],
    trust_level :: float(),
    is_active :: boolean(),
    pid :: pid() | undefined
}).

-record(distributed_entropy_network, {
    nodes :: [#node{}],
    topology :: [{non_neg_integer(), non_neg_integer()}],
    global_entropy_pool :: [boolean()],
    consensus_round :: non_neg_integer(),
    network_quality :: float()
}).

-record(state, {
    network :: #distributed_entropy_network{},
    node_processes :: #{non_neg_integer() => pid()},
    consensus_timer :: reference() | undefined
}).

-endif.
