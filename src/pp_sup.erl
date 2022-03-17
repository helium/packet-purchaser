%%%-------------------------------------------------------------------
%% @doc packet_purchaser top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(pp_sup).

-behaviour(supervisor).

-include("packet_purchaser.hrl").

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
    Key = load_key(BaseDir),
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

    ok = pp_utils:init_ets(),
    _ = pp_utils:get_chain(),
    ok = pp_location:init_ets(),
    ok = pp_downlink:init_ets(),

    ChildSpecs = [
        ?SUP(blockchain_sup, [BlockchainOpts]),
        ?WORKER(pp_config, [ConfigFilename]),
        ?WORKER(pp_sc_worker, [#{}]),
        ?WORKER(pp_location, []),
        ?SUP(pp_udp_sup, []),
        ?SUP(pp_http_sup, []),
        ?SUP(pp_console_sup, []),
        ?WORKER(pp_metrics, []),
        ?WORKER(pp_multi_buy, [])
    ],
    {ok, {?FLAGS, ChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================

-spec load_key(string()) ->
    {libp2p_crypto:pubkey(), libp2p_crypto:sig_fun(), libp2p_crypto:ecdh_fun()}.
load_key(BaseDir) ->
    SwarmKey = filename:join([BaseDir, "blockchain", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    case libp2p_crypto:load_keys(SwarmKey) of
        {ok, #{secret := PrivKey, public := PubKey}} ->
            {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)};
        {error, enoent} ->
            KeyMap =
                #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(
                    ecc_compact
                ),
            ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
            {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)}
    end.

-spec get_seed_nodes() -> list().
get_seed_nodes() ->
    case application:get_env(blockchain, seed_nodes) of
        {ok, ""} -> [];
        {ok, Seeds} -> string:split(Seeds, ",", all);
        _ -> []
    end.
