-module(pp_metrics).

-behaviour(gen_server).

-define(PACKET_ETS, pp_net_id_packet_count).
-define(LNS_ETS, lns_stats_ets).

%% gen_server API
-export([start_link/0]).

%% Metrics API
-export([
    get_netid_packet_counts/0,
    get_location_packet_counts/0,
    get_lns_metrics/0,
    handle_packet/2
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

-record(state, {
    seen :: #{
        libp2p_crypto:pubkey_bin() => {Country :: binary(), State :: binary(), City :: binary()}
    }
}).

-type lns_address() :: inet:socket_address() | inet:hostname().

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec handle_packet(
    NetID :: non_neg_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> ok.
handle_packet(NetID, PubKeyBin) ->
    %% update net id counter
    ok = inc_netid(NetID),

    %% count by overall location
    ok = maybe_fetch_location(PubKeyBin),

    ok.

-spec get_netid_packet_counts() -> map().
get_netid_packet_counts() ->
    maps:from_list([{NetId, Count} || {{count, NetId}, Count} <- ets:tab2list(?PACKET_ETS)]).

-spec get_location_packet_counts() -> map().
get_location_packet_counts() ->
    maps:from_list([{Location, Count} || {{location, Location}, Count} <- ets:tab2list(?PACKET_ETS)]).

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
%% Internal gen_server API
%% -------------------------------------------------------------------

-spec maybe_fetch_location(libp2p_crypto:pubkey_bin()) -> ok.
maybe_fetch_location(PubKeyBin) ->
    gen_server:cast(?MODULE, {location, PubKeyBin}).

%% -------------------------------------------------------------------
%% gen_server Callbacks
%% -------------------------------------------------------------------

init([]) ->
    ok = init_ets(),
    {ok, #state{seen = #{}}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast({location, PubKeyBin}, #state{seen = SeenMap} = State) ->
    Location =
        case maps:get(PubKeyBin, SeenMap, undefined) of
            undefined -> fetch_location(PubKeyBin);
            Result -> Result
        end,
    ok = inc_location(Location),
    NewSeenMap = maps:put(PubKeyBin, Location, SeenMap),
    {noreply, State#state{seen = NewSeenMap}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({multi_buy_evict, PHash}, State) ->
    ok = pp_sc_packet_handler:clear_multi_buy(PHash),
    {noreply, State};
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
        {ok, ?PACKET_ETS} ->
            lager:info("Packet metrics continued from last shutdown");
        {error, _} = Err ->
            lager:warning("Unable to open ~p ~p. Metrics will start over", [File, Err]),
            ?PACKET_ETS = ets:new(?PACKET_ETS, [public, named_table, set])
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
    ok = ets:tab2file(?PACKET_ETS, File, [{sync, true}]),
    File2 = pp_utils:get_lns_metrics_filename(),
    ok = ets:tab2file(?LNS_ETS, File2, [{sync, true}]),
    ok.

-spec inc_netid(integer()) -> ok.
inc_netid(NetID) ->
    Key = {count, NetID},
    _ = ets:update_counter(?PACKET_ETS, Key, 1, {Key, 0}),
    ok.

-spec inc_location(location_not_defined | {binary(), binary()}) -> ok.
inc_location(Location) ->
    Key = {location, Location},
    _ = ets:update_counter(?PACKET_ETS, Key, 1, {Key, 0}),
    ok.

-spec inc_lns_metric(Address :: lns_address(), pull_ack | push_ack, hit | miss) -> ok.
inc_lns_metric(LNSAddress, MessageType, Status) ->
    Key = {lns, LNSAddress, {MessageType, Status}},
    _ = ets:update_counter(?LNS_ETS, Key, 1, {Key, 0}),
    ok.

-spec fetch_location(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {Country :: binary(), State :: binary(), City :: binary()}
    | {Err, PubKeyBin :: libp2p_crypto:pubkey_bin()}
when
    Err :: location_not_set | fetch_failed.
fetch_location(PubKeyBin) ->
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    Prefix = "https://api.helium.io/v1/hotspots/",
    Url = erlang:list_to_binary(io_lib:format("~s~s", [Prefix, B58])),

    case hackney:get(Url, [], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            Map = jsx:decode(Body, [return_maps]),

            Location = {
                kvc:path("data.geocode.long_country", Map),
                kvc:path("data.geocode.long_state", Map),
                kvc:path("data.geocode.long_city", Map)
            },
            case Location of
                {null, null, null} -> {location_not_set, PubKeyBin};
                _ -> Location
            end;
        _Other ->
            lager:info("fetching hotspot region failed: ~p", [_Other]),
            {fetch_failed, PubKeyBin}
    end.
