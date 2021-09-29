%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser xor filter worker ==
%% @end
%%%-------------------------------------------------------------------
-module(pp_xor_filter_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(POST_INIT_TICK, post_init).
-define(POST_INIT_TIMER, 500).
-define(CHECK_FILTERS_TICK, check_filters).
-define(CHECK_FILTERS_TIMER, timer:minutes(10)).
-define(HASH_FUN, fun xxhash:hash64/1).
-define(SUBMIT_RESULT, submit_result).

-type device_dev_eui_app_eui() :: binary().
-type devices_dev_eui_app_eui() :: list(device_dev_eui_app_eui()).

-record(state, {
    chain :: undefined | blockchain:blockchain(),
    oui :: undefined | non_neg_integer(),
    pending_txns = #{} :: #{
        blockchain_txn:hash() => {non_neg_integer(), devices_dev_eui_app_eui()}
    },
    filter_to_devices = #{} :: #{non_neg_integer() => devices_dev_eui_app_eui()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    case enabled() of
        true ->
            ok = schedule_post_init();
        false ->
            ok
    end,
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?POST_INIT_TICK, #state{chain = undefined} = State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            ok = schedule_post_init(),
            {noreply, State};
        Chain ->
            case pp_utils:get_oui() of
                undefined ->
                    ok = schedule_post_init(),
                    {noreply, State};
                OUI ->
                    ok = schedule_check_filters(1),
                    {noreply, State#state{chain = Chain, oui = OUI}}
            end
    end;
handle_info(
    ?CHECK_FILTERS_TICK,
    #state{
        chain = Chain,
        oui = OUI,
        filter_to_devices = FilterToDevices,
        pending_txns = Pendings0
    } = State
) ->
    case should_update_filters(Chain, OUI, FilterToDevices) of
        noop ->
            lager:info("filters are still up to date"),
            ok = schedule_check_filters(default_timer()),
            {noreply, State};
        {Routing, Updates} ->
            CurrNonce = blockchain_ledger_routing_v1:nonce(Routing),
            {Pendings1, _} = lists:foldl(
                fun
                    ({new, NewDevicesDevEuiAppEui}, {Pendings, Nonce}) ->
                        lager:info("adding new filter"),
                        {Filter, _} = xor16:new(NewDevicesDevEuiAppEui, ?HASH_FUN),
                        Txn = craft_new_filter_txn(Chain, OUI, Filter, Nonce + 1),
                        Hash = submit_txn(Txn),
                        lager:info("new filter txn ~p submitted ~p", [
                            Hash,
                            lager:pr(Txn, blockchain_txn_routing_v1)
                        ]),
                        Index =
                            erlang:length(blockchain_ledger_routing_v1:filters(Routing)) + 1,
                        {maps:put(Hash, {Index, NewDevicesDevEuiAppEui}, Pendings), Nonce + 1};
                    ({update, Index, NewDevicesDevEuiAppEui}, {Pendings, Nonce}) ->
                        lager:info("updating filter @ index ~p", [Index]),
                        {Filter, _} = xor16:new(NewDevicesDevEuiAppEui, ?HASH_FUN),
                        Txn = craft_update_filter_txn(Chain, OUI, Filter, Nonce + 1, Index),
                        Hash = submit_txn(Txn),
                        lager:info("updating filter txn ~p submitted ~p", [
                            Hash,
                            lager:pr(Txn, blockchain_txn_routing_v1)
                        ]),
                        {maps:put(Hash, {Index, NewDevicesDevEuiAppEui}, Pendings), Nonce + 1}
                end,
                {Pendings0, CurrNonce},
                Updates
            ),
            {noreply, State#state{pending_txns = Pendings1}}
    end;
handle_info(
    {?SUBMIT_RESULT, Hash, ok},
    #state{
        pending_txns = Pendings,
        filter_to_devices = FilterToDevices
    } = State0
) ->
    {Index, DevicesDevEuiAppEui} = maps:get(Hash, Pendings),
    lager:info("successfully submitted txn: ~p added ~p to filter ~p", [
        lager:pr(Hash, blockchain_txn_routing_v1),
        DevicesDevEuiAppEui,
        Index
    ]),
    State1 = State0#state{
        pending_txns = maps:remove(Hash, Pendings),
        filter_to_devices = maps:put(Index, DevicesDevEuiAppEui, FilterToDevices)
    },
    case State1#state.pending_txns == #{} of
        false ->
            lager:info("waiting for more txn to clear");
        true ->
            lager:info("all txns cleared"),
            schedule_check_filters(default_timer())
    end,
    {noreply, State1};
handle_info(
    {?SUBMIT_RESULT, Hash, Return},
    #state{
        pending_txns = Pendings
    } = State0
) ->
    lager:error("failed to submit txn: ~p / ~p", [
        lager:pr(Hash, blockchain_txn_routing_v1),
        Return
    ]),
    State1 = State0#state{pending_txns = maps:remove(Hash, Pendings)},
    case State1#state.pending_txns == #{} of
        false ->
            lager:info("waiting for more txn to clear");
        true ->
            lager:info("all txns cleared"),
            schedule_check_filters(1)
    end,
    {noreply, State1};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec should_update_filters(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    FilterToDevices :: map()
) ->
    noop
    | {blockchain_ledger_routing_v1:routing(), [
        {new, devices_dev_eui_app_eui()}
        | {update, non_neg_integer(), devices_dev_eui_app_eui()}
    ]}.
should_update_filters(Chain, OUI, FilterToDevices) ->
    try pp_integration:get_devices() of
        {error, _Reason} ->
            lager:error("failed to get device ~p", [_Reason]),
            noop;
        {ok, DevicesDevEuiAppEui} ->
            Ledger = blockchain:ledger(Chain),
            {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),
            {ok, MaxXorFilter} = blockchain:config(max_xor_filter_num, Ledger),
            BinFilters = blockchain_ledger_routing_v1:filters(Routing),
            case contained_in_filters(BinFilters, FilterToDevices, DevicesDevEuiAppEui) of
                {_Map, [], Removed} when Removed == #{} ->
                    noop;
                {Map, Added, Removed} when Removed == #{} ->
                    case erlang:length(BinFilters) < MaxXorFilter of
                        true ->
                            {Routing, [{new, Added}]};
                        false ->
                            [{Index, SmallestDevicesDevEuiAppEui} | _] = smallest_first(
                                maps:to_list(Map)
                            ),
                            {Routing, [
                                {update, Index, Added ++ SmallestDevicesDevEuiAppEui}
                            ]}
                    end;
                {Map, [], Removed} ->
                    {Routing, craft_remove_updates(Map, Removed)};
                {Map, Added, Removed} ->
                    [{update, Index, R} | OtherUpdates] = smallest_first(
                        craft_remove_updates(Map, Removed)
                    ),
                    {Routing, [{update, Index, R ++ Added} | OtherUpdates]}
            end
    catch
        exit:{timeout, Err} ->
            lager:error("failed to get devices from integration", [Err]),
            noop
    end.

-spec smallest_first([{any(), L1 :: list()} | {any(), any(), L1 :: list()}]) -> list().
smallest_first(List) ->
    lists:sort(
        fun
            ({_, L1}, {_, L2}) ->
                erlang:length(L1) < erlang:length(L2);
            ({_, _, L1}, {_, _, L2}) ->
                erlang:length(L1) < erlang:length(L2)
        end,
        List
    ).

-spec craft_remove_updates(map(), map()) ->
    list({update, non_neg_integer(), devices_dev_eui_app_eui()}).
craft_remove_updates(Map, RemovedDevicesDevEuiAppEuiMap) ->
    maps:fold(
        fun(Index, RemovedDevicesDevEuiAppEui, Acc) ->
            [
                {update, Index, maps:get(Index, Map, []) -- RemovedDevicesDevEuiAppEui}
                | Acc
            ]
        end,
        [],
        RemovedDevicesDevEuiAppEuiMap
    ).

%% Return {map of IN FILTER device_dev_eui_app_eui indexed by their filter,
%%         list of added device
%%         map of REMOVED device_dev_eui_app_eui indexed by their filter}
-spec contained_in_filters(
    BinFilters :: list(binary()),
    FilterToDevices :: map(),
    DevicesDevEuiAppEui :: devices_dev_eui_app_eui()
) ->
    {#{non_neg_integer() => devices_dev_eui_app_eui()}, devices_dev_eui_app_eui(), #{
        non_neg_integer() => devices_dev_eui_app_eui()
    }}.
contained_in_filters(BinFilters, FilterToDevices, DevicesDevEuiAppEui) ->
    BinFiltersWithIndex = lists:zip(lists:seq(1, erlang:length(BinFilters)), BinFilters),
    ContainedBy = fun(Filter) -> fun(Bin) -> xor16:contain({Filter, ?HASH_FUN}, Bin) end end,
    {CurrFilter, Removed, Added, _} =
        lists:foldl(
            fun({Index, Filter}, {InFilterAcc0, RemovedAcc0, AddedToCheck, RemovedToCheck}) ->
                {AddedInFilter, AddedLeftover} = lists:partition(
                    ContainedBy(Filter),
                    AddedToCheck
                ),
                InFilterAcc1 =
                    case AddedInFilter == [] of
                        false -> maps:put(Index, AddedInFilter, InFilterAcc0);
                        true -> InFilterAcc0
                    end,
                {RemovedInFilter, RemovedLeftover} = lists:partition(
                    ContainedBy(Filter),
                    RemovedToCheck
                ),
                RemovedAcc1 =
                    case RemovedInFilter == [] of
                        false -> maps:put(Index, RemovedInFilter, RemovedAcc0);
                        true -> RemovedAcc0
                    end,
                {InFilterAcc1, RemovedAcc1, AddedLeftover, RemovedLeftover}
            end,
            {#{}, #{}, DevicesDevEuiAppEui,
                lists:flatten(maps:values(FilterToDevices)) -- DevicesDevEuiAppEui},
            BinFiltersWithIndex
        ),
    {CurrFilter, Added, Removed}.

-spec craft_new_filter_txn(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference(),
    Nonce :: non_neg_integer()
) -> blockchain_txn_routing_v1:txn_routing().
craft_new_filter_txn(Chain, OUI, Filter, Nonce) ->
    {ok, PubKey, SignFun, _} = blockchain_swarm:keys(),
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Txn0 = blockchain_txn_routing_v1:new_xor(
        OUI,
        libp2p_crypto:pubkey_to_bin(PubKey),
        BinFilter,
        Nonce
    ),
    Fees = blockchain_txn_routing_v1:calculate_fee(Txn0, Chain),
    Txn1 = blockchain_txn_routing_v1:fee(Txn0, Fees),
    blockchain_txn_routing_v1:sign(Txn1, SignFun).

-spec craft_update_filter_txn(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference(),
    Nonce :: non_neg_integer(),
    Index :: non_neg_integer()
) -> blockchain_txn_routing_v1:txn_routing().
craft_update_filter_txn(Chain, OUI, Filter, Nonce, Index) ->
    {ok, PubKey, SignFun, _} = blockchain_swarm:keys(),
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Txn0 = blockchain_txn_routing_v1:update_xor(
        OUI,
        libp2p_crypto:pubkey_to_bin(PubKey),
        Index,
        BinFilter,
        Nonce
    ),
    Fees = blockchain_txn_routing_v1:calculate_fee(Txn0, Chain),
    Txn1 = blockchain_txn_routing_v1:fee(Txn0, Fees),
    blockchain_txn_routing_v1:sign(Txn1, SignFun).

-spec submit_txn(Txn :: blockchain_txn_routing_v1:txn_routing()) -> blockchain_txn:hash().
submit_txn(Txn) ->
    Hash = blockchain_txn_routing_v1:hash(Txn),
    Self = self(),
    Callback = fun(Return) -> Self ! {?SUBMIT_RESULT, Hash, Return} end,
    ok = blockchain_worker:submit_txn(Txn, Callback),
    Hash.

-spec schedule_post_init() -> ok.
schedule_post_init() ->
    {ok, _} = timer:send_after(?POST_INIT_TIMER, self(), ?POST_INIT_TICK),
    ok.

-spec schedule_check_filters(non_neg_integer()) -> ok.
schedule_check_filters(Timer) ->
    _Ref = erlang:send_after(Timer, self(), ?CHECK_FILTERS_TICK),
    ok.

-spec enabled() -> boolean().
enabled() ->
    case application:get_env(packet_purchaser, pp_xor_filter_worker, false) of
        "true" -> true;
        true -> true;
        _ -> false
    end.

-spec default_timer() -> non_neg_integer().
default_timer() ->
    case
        application:get_env(
            packet_purchaser,
            pp_xor_filter_worker_timer,
            ?CHECK_FILTERS_TIMER
        )
    of
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        I -> I
    end.
