-define(DEFAULT_HTTP_FLOW_TYPE, <<"sync">>).
-define(DEFAULT_HTTP_DEDUPE_TIMEOUT, 200).
-define(DEFAULT_HTTP_PROTOCOL_VERSION, <<"1.1">>).

-define(DEFAULT_ACTIVE, true).
-define(DEFAULT_MULTI_BUY, unlimited).
-define(DEFAULT_PROTOCOL_VERSION, pv_1_1).
-define(DEFAULT_DEDUPE_TIMEOUT, 200).
-define(DEFAULT_FLOW_TYPE, <<"sync">>).

-type protocol_version() :: pv_1_0 | pv_1_1.

-record(http_protocol, {
    endpoint :: binary(),
    flow_type :: async | sync,
    dedupe_timeout :: non_neg_integer(),
    auth_header :: null | binary(),
    protocol_version :: protocol_version()
}).

-record(udp, {
    address :: string(),
    port :: non_neg_integer()
}).

-type protocol() :: not_configured | #http_protocol{} | #udp{}.

-record(eui, {
    name :: undefined | binary(),
    net_id :: non_neg_integer(),
    multi_buy :: unlimited | non_neg_integer(),
    dev_eui :: '*' | non_neg_integer(),
    app_eui :: non_neg_integer(),
    console_active = true :: boolean(),
    buying_active = true :: boolean(),
    protocol :: protocol(),
    %% TODO remove eventually
    disable_pull_data = false :: boolean(),
    ignore_disable = false :: boolean()
}).

-record(devaddr, {
    name :: undefined | binary(),
    net_id :: non_neg_integer(),
    multi_buy :: unlimited | non_neg_integer(),
    console_active = true :: boolean(),
    buying_active = true :: boolean(),
    addr :: {single, integer()} | {range, integer(), integer()},
    protocol :: protocol(),
    %% TODO remove eventually
    disable_pull_data = false :: boolean(),
    ignore_disable = false :: boolean()
}).
