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

handle_info(post_init, #state{chain = undefined} = State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            ok = schedule_post_init(),
            {noreply, State};
        Chain ->
            case pp_utils:get_oui(Chain) of
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
    case pp_integration:get_devices() of
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

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

should_update_filters_test() ->
    OUI = 1,

    meck:new(blockchain, [passthrough]),
    meck:new(pp_integration, [passthrough]),
    meck:new(blockchain_ledger_v1, [passthrough]),

    %% ------------------------
    %% We start by testing if we got 0 device from API
    meck:expect(blockchain, ledger, fun(_) -> ledger end),
    %% This set the max xor filter chain var
    meck:expect(blockchain, config, fun(_, _) -> {ok, 2} end),
    meck:expect(pp_integration, get_devices, fun() -> {error, any} end),

    ?assertEqual(noop, should_update_filters(chain, OUI, #{})),

    %% ------------------------
    %% Testing if no devices were added or removed
    Device0 = <<"deveui0app_eui0">>,
    meck:expect(pp_integration, get_devices, fun() ->
        {ok, [Device0]}
    end),

    {Filter, _} = xor16:new([Device0], ?HASH_FUN),
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Routing0 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, Routing0}
    end),

    ?assertEqual(noop, should_update_filters(chain, OUI, #{})),

    %% ------------------------
    %% Testing if a device was added
    {EmptyFilter, _} = xor16:new([], ?HASH_FUN),
    {BinEmptyFilter, _} = xor16:to_bin({EmptyFilter, ?HASH_FUN}),
    EmptyRouting = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinEmptyFilter, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, EmptyRouting}
    end),

    ?assertEqual(
        {EmptyRouting, [{new, [Device0]}]},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    %% Testing if a device was added but we have at our max filter (set to 1)
    meck:expect(blockchain, config, fun(_, _) -> {ok, 1} end),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, Routing0}
    end),
    Device1 = <<"deveui1app_eui1">>,
    meck:expect(pp_integration, get_devices, fun() ->
        {ok, [Device0, Device1]}
    end),

    ?assertEqual(
        {Routing0, [{update, 1, [Device1, Device0]}]},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Testing that we removed Device0
    meck:expect(blockchain, config, fun(_, _) -> {ok, 2} end),
    meck:expect(pp_integration, get_devices, fun() ->
        {ok, [Device1]}
    end),

    ?assertEqual(
        {Routing0, [{update, 1, [Device1]}]},
        should_update_filters(chain, OUI, #{
            1 => [Device0]
        })
    ),

    %% ------------------------
    % Testing that we removed Device0 and added Device2
    Device2 = <<"deveui2app_eui2">>,
    meck:expect(pp_integration, get_devices, fun() ->
        {ok, [Device1, Device2]}
    end),

    ?assertEqual(
        {Routing0, [{update, 1, [Device1, Device2]}]},
        should_update_filters(chain, OUI, #{
            1 => [Device0]
        })
    ),

    %% ------------------------
    % Testing that we removed Device0 and Device1 but from diff filters
    {Filter0, _} = xor16:new([Device0], ?HASH_FUN),
    {BinFilter0, _} = xor16:to_bin({Filter0, ?HASH_FUN}),
    RoutingRemoved0 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter0, [], 1),
    {Filter1, _} = xor16:new([Device1], ?HASH_FUN),
    {BinFilter1, _} = xor16:to_bin({Filter1, ?HASH_FUN}),
    RoutingRemoved1 = blockchain_ledger_routing_v1:update(
        RoutingRemoved0,
        {new_xor, BinFilter1},
        2
    ),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, RoutingRemoved1}
    end),

    meck:expect(pp_integration, get_devices, fun() ->
        {ok, []}
    end),

    ?assertEqual(
        {RoutingRemoved1, [{update, 2, []}, {update, 1, []}]},
        should_update_filters(chain, OUI, #{
            1 => [Device0],
            2 => [Device1]
        })
    ),

    meck:unload(blockchain_ledger_v1),
    meck:unload(pp_integration),
    meck:unload(blockchain),
    ok.

contained_in_filters_test() ->
    BinDevices = lists:foldl(
        fun(_, Acc) ->
            [crypto:strong_rand_bytes(16) | Acc]
        end,
        [],
        lists:seq(1, 10)
    ),
    {BinDevices1, BinDevices2} = lists:split(5, BinDevices),
    {Filter1, _} = xor16:new(BinDevices1, ?HASH_FUN),
    {BinFilter1, _} = xor16:to_bin({Filter1, ?HASH_FUN}),
    {Filter2, _} = xor16:new(BinDevices2, ?HASH_FUN),
    {BinFilter2, _} = xor16:to_bin({Filter2, ?HASH_FUN}),
    ?assertEqual(
        {#{1 => BinDevices1, 2 => BinDevices2}, [], #{}},
        contained_in_filters([BinFilter1, BinFilter2], #{}, BinDevices)
    ),
    ?assertEqual(
        {#{1 => BinDevices1}, BinDevices2, #{}},
        contained_in_filters([BinFilter1], #{}, BinDevices)
    ),
    ?assertEqual(
        {#{1 => BinDevices1}, [], #{2 => BinDevices2}},
        contained_in_filters([BinFilter1, BinFilter2], #{1 => BinDevices2}, BinDevices1)
    ),
    ?assertEqual(
        {#{}, BinDevices2, #{1 => BinDevices1}},
        contained_in_filters([BinFilter1], #{1 => BinDevices1}, BinDevices2)
    ),
    ok.

-endif.
