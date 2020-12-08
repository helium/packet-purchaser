%%%-------------------------------------------------------------------
%% @doc packet_purchaser top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(packet_purchaser_sup).

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
    lager:info("init ~p", [?SERVER]),
    {ok, _} = application:ensure_all_started(lager),
    {ok, _} = application:ensure_all_started(ranch),

    BaseDir = application:get_env(blockchain, base_dir, "data"),
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
    SCWorkerOpts = #{},
    ChildSpecs = [
        ?SUP(blockchain_sup, [BlockchainOpts]),
        ?WORKER(packet_purchaser_sc_worker, [SCWorkerOpts]),
        ?SUP(packet_purchaser_udp_sup, [])
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
