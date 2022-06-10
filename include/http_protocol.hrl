-define(DEFAULT_HTTP_FLOW_TYPE, <<"sync">>).
-define(DEFAULT_HTTP_DEDUPE_TIMEOUT, 200).
-define(DEFAULT_HTTP_PROTOCOL_VERSION, <<"1.1">>).

-type protocol_version() :: pv_1_0 | pv_1_1.

-record(http_protocol, {
    endpoint :: binary(),
    flow_type :: async | sync,
    dedupe_timeout :: non_neg_integer(),
    auth_header :: null | binary(),
    protocol_version :: protocol_version()
}).
