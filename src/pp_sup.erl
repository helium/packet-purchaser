%%%-------------------------------------------------------------------
%% @doc packet_purchaser top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(pp_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(FLAGS, #{
    strategy => rest_for_one,
    intensity => 1,
    period => 5
}).

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [I]
}).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    {ok, _} = application:ensure_all_started(lager),
    {ok, _} = application:ensure_all_started(ranch),
    lager:info("init ~p", [?SERVER]),

    BaseDir = application:get_env(blockchain, base_dir, "data"),
    ok = libp2p_crypto:set_network(application:get_env(libp2p, network, mainnet)),
    Key = pp_utils:load_key(BaseDir),
    SeedNodes = get_seed_nodes(),
    BlockchainOpts = [
        {key, Key},
        {seed_nodes, SeedNodes},
        {max_inbound_connections, 10},
        {port, application:get_env(blockchain, port, 0)},
        {base_dir, BaseDir},
        {update_dir, application:get_env(blockchain, update_dir, undefined)}
    ],

    {ok, ConfigFilename} = application:get_env(packet_purchaser, pp_routing_config_filename),

    ok = pp_multi_buy:init(),
    ok = pp_config:init_ets(),
    ok = pp_utils:init_ets(),
    ok = pp_metrics:init_ets(),
    ok = pp_ics_gateway_location_worker:init_ets(),

    ElliConfig = [
        {callback, pp_roaming_downlink},
        {port, pp_utils:get_env_int(http_roaming_port, 8081)}
    ],

    MetricsConfig = application:get_env(packet_purchaser, metrics, []),

    POCDenyListArgs =
        case
            {
                application:get_env(packet_purchaser, denylist_keys, undefined),
                application:get_env(packet_purchaser, denylist_url, undefined)
            }
        of
            {undefined, _} ->
                #{};
            {_, undefined} ->
                #{};
            {DenyListKeys, DenyListUrl} ->
                #{
                    denylist_keys => DenyListKeys,
                    denylist_url => DenyListUrl,
                    denylist_base_dir => BaseDir,
                    denylist_check_timer => {immediate, timer:hours(12)}
                }
        end,

    PacketReporterConfig = application:get_env(packet_purchaser, packet_reporter, #{}),
    {PubKey0, SigFun, _} = Key,
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey0),
    ICSOptsDefault = application:get_env(packet_purchaser, ics, #{}),
    ICSOpts = ICSOptsDefault#{pubkey_bin => PubKeyBin, sig_fun => SigFun},

    BlockChainWorkers =
        case pp_utils:is_chain_dead() of
            true ->
                [];
            false ->
                [
                    ?SUP(blockchain_sup, [BlockchainOpts]),
                    ?WORKER(pp_sc_worker, [#{}])
                ]
        end,

    ChildSpecs =
        [
            ?WORKER(pg, []),
            ?WORKER(ru_poc_denylist, [POCDenyListArgs]),
            ?WORKER(pp_config, [ConfigFilename]),
            ?WORKER(pp_packet_reporter, [PacketReporterConfig]),
            ?WORKER(pp_ics_gateway_location_worker, [ICSOpts])
        ] ++
            BlockChainWorkers ++
            [
                ?SUP(pp_udp_sup, []),
                ?SUP(pp_http_sup, []),
                ?SUP(pp_console_sup, []),
                ?WORKER(pp_metrics, [MetricsConfig]),
                #{
                    id => pp_roaming_downlink,
                    start => {elli, start_link, [ElliConfig]},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [elli]
                }
            ],
    {ok, {?FLAGS, ChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================

-spec get_seed_nodes() -> list().
get_seed_nodes() ->
    case application:get_env(blockchain, seed_nodes) of
        {ok, ""} -> [];
        {ok, Seeds} -> string:split(Seeds, ",", all);
        _ -> []
    end.
