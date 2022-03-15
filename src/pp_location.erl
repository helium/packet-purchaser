-module(pp_location).

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    init_ets/0,
    get_hotspot_location/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(PP_LOCATION_ETS, pp_location_ets).

-record(state, {
    chain :: undefined | blockchain:blockchain()
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec init_ets() -> ok.
init_ets() ->
    ?PP_LOCATION_ETS = ets:new(?PP_LOCATION_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true}
    ]),
    ok.

-spec get_hotspot_location(PubKeyBin :: binary()) ->
    unknown
    | {Index :: pos_integer(), Lat :: float(), Long :: float()}.
get_hotspot_location(PubKeyBin) ->
    case ets:lookup(?PP_LOCATION_ETS, PubKeyBin) of
        [] ->
            gen_server:cast(?MODULE, {fetch_hotspot_location, PubKeyBin}),
            true = ets:insert(?PP_LOCATION_ETS, {PubKeyBin, fetching}),
            unknown;
        [{PubKeyBin, fetching}] ->
            unknown;
        [{PubKeyBin, unknown}] ->
            unknown;
        [{PubKeyBin, Location}] ->
            Location
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Args) ->
    erlang:send_after(0, self(), get_blockchain),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({fetch_hotspot_location, PubKeyBin}, #state{chain = Chain} = State) ->
    case Chain of
        undefined ->
            undefined;
        _ ->
            Ledger = blockchain:ledger(Chain),
            case blockchain_ledger_v1:find_gateway_info(PubKeyBin, Ledger) of
                {error, _} ->
                    true = ets:insert(?PP_LOCATION_ETS, {PubKeyBin, unknown}),
                    undefined;
                {ok, Hotspot} ->
                    case blockchain_ledger_gateway_v2:location(Hotspot) of
                        undefined ->
                            true = ets:insert(?PP_LOCATION_ETS, {PubKeyBin, unknown}),
                            undefined;
                        Index ->
                            {Lat, Long} = h3:to_geo(Index),
                            true = ets:insert(?PP_LOCATION_ETS, {PubKeyBin, {Index, Lat, Long}})
                    end
            end
    end,
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(get_blockchain, State) ->
    case pp_utils:get_chain() of
        fetching ->
            erlang:send_after(250, self(), get_blockchain),
            {noreply, State};
        Chain ->
            {noreply, State#state{chain = Chain}}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
