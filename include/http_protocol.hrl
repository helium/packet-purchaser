-define(DEFAULT_HTTP_FLOW_TYPE, <<"sync">>).
-define(DEFAULT_HTTP_DEDUPE_TIMEOUT, 200).

-record(http_protocol, {
    endpoint :: binary(),
    flow_type :: async | sync,
    dedupe_timeout :: non_neg_integer(),
    auth_header :: null | binary()
}).
