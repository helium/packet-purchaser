-module(pp_metrics).

-behaviour(gen_server).

-define(ETS, pp_net_id_packet_count).

%% gen_server API
-export([start_link/0]).

%% Metrics API
-export([
    get_netid_packet_counts/0,
    get_location_packet_counts/0,
    handle_packet/2
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

-record(state, {seen :: #{libp2p_crypto:pubkey_bin() => {Country :: binary(), City :: binary()}}}).

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
    maps:from_list([{NetId, Count} || {{count, NetId}, Count} <- ets:tab2list(?ETS)]).

-spec get_location_packet_counts() -> map().
get_location_packet_counts() ->
    maps:from_list([{Location, Count} || {{location, Location}, Count} <- ets:tab2list(?ETS)]).

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
            lager:info("Metrics continued from last shutdown");
        {error, _} = Err ->
            lager:warning("Unable to open ~p ~p. Metrics will start over", [File, Err]),
            ?ETS = ets:new(?ETS, [public, named_table, set])
    end,
    ok.

-spec cleanup_ets() -> ok.
cleanup_ets() ->
    File = pp_utils:get_metrics_filename(),
    ok = ets:tab2file(?ETS, File, [{sync, true}]),
    ok.

-spec inc_netid(integer()) -> ok.
inc_netid(NetID) ->
    Key = {count, NetID},
    _ = ets:update_counter(?ETS, Key, 1, {Key, 0}),
    ok.

-spec inc_location(location_not_defined | {binary(), binary()}) -> ok.
inc_location(Location) ->
    Key = {location, Location},
    _ = ets:update_counter(?ETS, Key, 1, {Key, 0}),
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
