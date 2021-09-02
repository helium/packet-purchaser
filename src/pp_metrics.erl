-module(pp_metrics).

-behaviour(gen_server).

-define(LNS_ETS, lns_stats_ets).
-define(ETS, pp_metrics_ets).

%% gen_server API
-export([start_link/0]).

%% Metrics API
-export([
    get_netid_packet_counts/0,
    get_location_packet_counts/0,
    get_lns_metrics/0,
    handle_packet/2,
    handle_offer/2
]).

-export([
    push_ack/1,
    push_ack_missed/1,
    pull_ack/1,
    pull_ack_missed/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(hotspot, {
    address :: binary(),
    name :: binary(),
    country :: binary(),
    state :: binary(),
    city :: binary(),
    geo :: {Lat :: float(), Long :: float()},
    hex :: binary()
}).

-record(state, {
    seen :: #{libp2p_crypto:pubkey_bin() => #hotspot{}}
}).

-type lns_address() :: inet:socket_address() | inet:hostname().

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec handle_offer(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
handle_offer(PubKeyBin, NetID) ->
    gen_server:cast(?MODULE, {offer, PubKeyBin, NetID}).

-spec handle_packet(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
handle_packet(PubKeyBin, NetID) ->
    gen_server:cast(?MODULE, {packet, PubKeyBin, NetID}).

-spec get_netid_packet_counts() -> map().
get_netid_packet_counts() ->
    Spec = [{{{packet, '_', '$1'}, '$2'}, [], [{{'$1', '$2'}}]}],
    Values = ets:select(?ETS, Spec),
    Fun = fun(Key) -> {Key, lists:sum(proplists:get_all_values(Key, Values))} end,
    maps:from_list(lists:map(Fun, proplists:get_keys(Values))).

-spec get_location_packet_counts() -> map().
get_location_packet_counts() ->
    Spec = [
        {{{packet, #hotspot{country = '$1', state = '$2', city = '$3', _ = '_'}, '$4'}, '$5'}, [], [
            {{{{'$1', '$2', '$3'}}, '$5'}}
        ]}
    ],
    Values = ets:select(?ETS, Spec),
    Fun = fun(Key) -> {Key, lists:sum(proplists:get_all_values(Key, Values))} end,
    maps:from_list(lists:map(Fun, proplists:get_keys(Values))).

-spec get_lns_metrics() -> map().
get_lns_metrics() ->
    lists:foldl(
        fun({{lns, Address, Key}, Count}, Agg) ->
            maps:update_with(Address, fun(Val) -> [{Key, Count} | Val] end, [{Key, Count}], Agg)
        end,
        #{},
        ets:tab2list(?LNS_ETS)
    ).

-spec push_ack(LNSAddress :: lns_address()) -> ok.
push_ack(Address) ->
    ok = inc_lns_metric(Address, push_ack, hit).

-spec push_ack_missed(LNSAddress :: lns_address()) -> ok.
push_ack_missed(Address) ->
    ok = inc_lns_metric(Address, push_ack, miss).

-spec pull_ack(LNSAddress :: lns_address()) -> ok.
pull_ack(Address) ->
    ok = inc_lns_metric(Address, pull_ack, hit).

-spec pull_ack_missed(LNSAddress :: lns_address()) -> ok.
pull_ack_missed(Address) ->
    ok = inc_lns_metric(Address, pull_ack, miss).

%% -------------------------------------------------------------------
%% gen_server Callbacks
%% -------------------------------------------------------------------

init([]) ->
    ok = init_ets(),
    {ok, #state{seen = #{}}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast({offer, PubKeyBin, NetID}, #state{seen = SeenMap} = State) ->
    Hotspot = get_hotspot(PubKeyBin, SeenMap),
    ok = inc_offer(Hotspot, NetID),
    NewSeenMap = maps:put(PubKeyBin, Hotspot, SeenMap),
    {noreply, State#state{seen = NewSeenMap}};
handle_cast({packet, PubKeyBin, NetID}, #state{seen = SeenMap} = State) ->
    Hotspot = get_hotspot(PubKeyBin, SeenMap),
    ok = inc_packet(Hotspot, NetID),
    NewSeenMap = maps:put(PubKeyBin, Hotspot, SeenMap),
    {noreply, State#state{seen = NewSeenMap}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok = cleanup_ets(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    File = pp_utils:get_metrics_filename(),
    case ets:file2tab(File) of
        {ok, ?ETS} ->
            lager:info("Packet metrics continued from last shutdown");
        {error, _} = Err ->
            lager:warning("Unable to open ~p ~p. Metrics will start over", [File, Err]),
            ?ETS = ets:new(?ETS, [public, named_table, set])
    end,
    File2 = pp_utils:get_lns_metrics_filename(),
    case ets:file2tab(File2) of
        {ok, ?LNS_ETS} ->
            lager:info("LNS metrics continued from last shutdown");
        {error, _} = Err2 ->
            lager:warning("Unable to topen ~p ~p. Metrics will start over", [File2, Err2]),
            ?LNS_ETS = ets:new(?LNS_ETS, [public, named_table, set, {write_concurrency, true}])
    end,
    ok.

-spec cleanup_ets() -> ok.
cleanup_ets() ->
    File = pp_utils:get_metrics_filename(),
    ok = ets:tab2file(?ETS, File, [{sync, true}]),
    File2 = pp_utils:get_lns_metrics_filename(),
    ok = ets:tab2file(?LNS_ETS, File2, [{sync, true}]),
    ok.

-spec inc_lns_metric(Address :: lns_address(), pull_ack | push_ack, hit | miss) -> ok.
inc_lns_metric(LNSAddress, MessageType, Status) ->
    Key = {lns, LNSAddress, {MessageType, Status}},
    _ = ets:update_counter(?LNS_ETS, Key, 1, {Key, 0}),
    ok.

-spec inc_packet(Hotspot :: #hotspot{}, NetID :: non_neg_integer()) -> ok.
inc_packet(Hotspot, NetID) ->
    Key = {packet, Hotspot, NetID},
    _ = ets:update_counter(?ETS, Key, 1, {Key, 0}),
    ok.

-spec inc_offer(Hotspot :: #hotspot{}, NetID :: non_neg_integer()) -> ok.
inc_offer(Hotspot, NetID) ->
    Key = {offer, Hotspot, NetID},
    _ = ets:update_counter(?ETS, Key, 1, {Key, 0}),
    ok.

-spec get_hotspot(PubKeyBin :: libp2p_crypto:pubkey_bin(), map()) -> #hotspot{}.
get_hotspot(PubKeyBin, SeenMap) ->
    case maps:get(PubKeyBin, SeenMap, undefined) of
        undefined -> fetch_hotspot(PubKeyBin);
        HS -> HS
    end.

-spec fetch_hotspot(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    #hotspot{} | {Err, PubKeyBin :: libp2p_crypto:pubkey_bin()}
when
    Err :: fetch_failed.
fetch_hotspot(PubKeyBin) ->
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    Prefix = "https://api.helium.io/v1/hotspots/",
    Url = erlang:list_to_binary(io_lib:format("~s~s", [Prefix, B58])),

    case hackney:get(Url, [], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            #{
                <<"data">> := #{
                    <<"lat">> := Lat,
                    <<"lng">> := Long,
                    <<"location_hex">> := LocationHex,
                    <<"name">> := Name,
                    <<"geocode">> := #{
                        <<"long_country">> := Country,
                        <<"long_state">> := State,
                        <<"long_city">> := City
                    }
                }
            } = jsx:decode(Body, [return_maps]),

            #hotspot{
                address = PubKeyBin,
                name = Name,
                country = Country,
                state = State,
                city = City,
                geo = {Lat, Long},
                hex = LocationHex
            };
        _Other ->
            lager:info("fetchign hotspots failed: ~p", [_Other]),
            {fetch_failed, PubKeyBin}
    end.
