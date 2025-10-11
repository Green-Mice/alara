-ifndef(ALARA_HRL).
-define(ALARA_HRL, true).

-record(node, {
    node_id :: pid()
}).

-record(state, {
    nodes :: [pid()],
    node_supervisor :: pid()
}).

-endif.
