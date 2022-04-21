%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser Multi Buy ==
%%
%% The first time a PHash is encountered it's inserted into the MB ets table
%% along with the time of the first purchase.
%%
%% Subsequent purchases will increment the number bought until we reach the
%% threshold and wrap around to a very low number.
%%
%% As long as the number bought is less than `0' no more will be purchased.
%%
%% A scheduled cleanup comes around and looks for all objects where the Time
%% position is far enough in the past to be deleted.
%%
%% @end %-------------------------------------------------------------------
-module(pp_multi_buy).

%% Multi-buy API
-export([
    maybe_buy_offer/2,
    init/0,
    cleanup/1
]).

-define(MB_ETS, multi_buy_ets).
-define(MB_MAX_BUY_RESET_VALUE, -9999).
-define(MB_MAX_PACKET, multi_buy_max_packet).
-define(MB_BUYING_DISABLED, multi_buy_disabled).
-define(MB_CLEANUP, timer:minutes(30)).

-spec init() -> ok.
init() ->
    ok = init_ets(),
    ok = scheduled_cleanup(?MB_CLEANUP),
    ok.

-spec init_ets() -> ok.
init_ets() ->
    ?MB_ETS = ets:new(?MB_ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ok.

-spec maybe_buy_offer(
    Offer :: blockchain_state_channel_offer_v1:offer(),
    MultiBuyMax :: unlimited | non_neg_integer()
) -> ok | {error, any()}.
maybe_buy_offer(Offer, MultiBuyMax) ->
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    maybe_buy(PHash, MultiBuyMax).

-spec maybe_buy(
    PHash :: binary(),
    MultiBuyMax :: unlimited | non_neg_integer()
) -> ok | {error, any()}.
maybe_buy(_Offer, 0) ->
    {error, ?MB_BUYING_DISABLED};
maybe_buy(_Offer, unlimited) ->
    ok;
maybe_buy(PHash, MultiBuyMax) ->
    case
        ets:update_counter(
            ?MB_ETS,
            PHash,
            {2, 1, MultiBuyMax, ?MB_MAX_BUY_RESET_VALUE},
            {default, 0, erlang:system_time(millisecond)}
        )
    of
        Count when Count =< 0 -> {error, ?MB_MAX_PACKET};
        _Count -> ok
    end.

-spec scheduled_cleanup(Duration :: non_neg_integer()) -> ok.
scheduled_cleanup(Duration) ->
    erlang:spawn(
        fun() ->
            ok = cleanup(Duration),
            timer:sleep(Duration),
            ok = scheduled_cleanup(Duration)
        end
    ),
    ok.

cleanup(Duration) ->
    Time = erlang:system_time(millisecond) - Duration,
    Expired = select_expired(Time),
    lists:foreach(fun(PHash) -> ets:delete(?MB_ETS, PHash) end, Expired),
    lager:debug("expiring ~p PHash", [erlang:length(Expired)]),
    ok.

-spec select_expired(Time :: non_neg_integer()) -> list(binary()).
select_expired(Time) ->
    ets:select(?MB_ETS, [
        {
            {'$1', '$2', '$3'},
            [{'<', '$3', Time}],
            ['$1']
        }
    ]).

%%====================================================================
%% Tests
%%====================================================================o

-ifdef(TEST).

-define(TEST_SLEEP, 250).
-define(TEST_PERF, 1000).

-include_lib("eunit/include/eunit.hrl").

multi_buy_test_() ->
    {
        foreach,
        fun() -> ok = init_ets() end,
        fun(_) -> _ = catch ets:delete(?MB_ETS) end,
        [
            fun test_maybe_buy/0,
            fun test_maybe_buy_only_1/0,
            fun test_maybe_buy_deny_more/0,
            fun test_cleanup_phash/0
        ]
    }.

test_maybe_buy() ->
    %% Setup Max packet for device
    Max = 5,

    Parent = self(),
    %% Setup phash and number of packet to be sent
    PHash = crypto:strong_rand_bytes(32),
    Packets = 100,
    lists:foreach(
        fun(X) ->
            %% Each "packet sending" is spawn and sleep for a random timer defined by
            %% ?TEST_SLEEP it will then attempt to buy and send back its result to Parent
            erlang:spawn(
                fun() ->
                    timer:sleep(rand:uniform(?TEST_SLEEP)),
                    {Time, Result} = timer:tc(fun() -> maybe_buy(PHash, Max) end),
                    Parent ! {maybe_buy_test, X, Time, Result}
                end
            )
        end,
        lists:seq(1, Packets)
    ),
    %% Aggregate results
    Results = maybe_buy_test_rcv_loop(#{}),
    %% Filter result to only find OKs and make sure we only have MAX OKs
    OK = maps:filter(fun(_K, {_, V}) -> V =:= ok end, Results),
    ?assertEqual(Max, maps:size(OK)),
    %% Filter result to only find Errors and make sure we have Packets-MAX Errors
    Errors = maps:filter(
        fun(_K, {_, V}) -> V =:= {error, ?MB_MAX_PACKET} end,
        Results
    ),
    ?assertEqual(Packets - Max, maps:size(Errors)),
    %% At this point a time marker should have been set in the table with that PHash
    ?assertMatch([{PHash, _, _}], ets:lookup(?MB_ETS, PHash)),
    %% performance check in MICRO seconds
    TotalTime = lists:sum([T || {T, _} <- maps:values(Results)]),
    ?assert(TotalTime / Packets < ?TEST_PERF),
    ok.

test_maybe_buy_only_1() ->
    %% Setup Max packet for device
    Max = 1,

    Parent = self(),
    %% Setup phash and number of packet to be sent
    PHash = crypto:strong_rand_bytes(32),
    Packets = 100,
    lists:foreach(
        fun(X) ->
            %% Each "packet sending" is spawn and sleep for a random timer defined by
            %% ?TEST_SLEEP it will then attempt to buy and send back its result to Parent
            erlang:spawn(
                fun() ->
                    timer:sleep(rand:uniform(?TEST_SLEEP)),
                    {Time, Result} = timer:tc(fun() -> maybe_buy(PHash, Max) end),
                    Parent ! {maybe_buy_test, X, Time, Result}
                end
            )
        end,
        lists:seq(1, Packets)
    ),
    %% Aggregate results
    Results = maybe_buy_test_rcv_loop(#{}),
    %% Filter result to only find OKs and make sure we only have MAX OKs
    OK = maps:filter(fun(_K, {_, V}) -> V =:= ok end, Results),
    ?assertEqual(Max, maps:size(OK)),
    %% Filter result to only find Errors and make sure we have Packets-MAX Errors
    Errors = maps:filter(
        fun(_K, {_, V}) -> V =:= {error, ?MB_MAX_PACKET} end,
        Results
    ),
    ?assertEqual(Packets - Max, maps:size(Errors)),
    %% At this point a time marker should have been set in the table with that PHash
    ?assertMatch([{PHash, _, _}], ets:lookup(?MB_ETS, PHash)),
    %% performance check in MICRO seconds
    TotalTime = lists:sum([T || {T, _} <- maps:values(Results)]),
    ?assert(TotalTime / Packets < ?TEST_PERF),

    ok.

test_maybe_buy_deny_more() ->
    %% Setup Max packet for device
    Max = 0,

    Parent = self(),
    %% Setup phash and number of packet to be sent
    PHash = crypto:strong_rand_bytes(32),
    Packets = 100,
    lists:foreach(
        fun(X) ->
            %% Each "packet sending" is spawn and sleep for a random timer defined by
            %% ?TEST_SLEEP it will then attempt to buy and send back its result to Parent
            erlang:spawn(
                fun() ->
                    timer:sleep(rand:uniform(?TEST_SLEEP)),
                    {Time, Result} = timer:tc(fun() -> maybe_buy(PHash, Max) end),
                    Parent ! {maybe_buy_test, X, Time, Result}
                end
            )
        end,
        lists:seq(1, Packets)
    ),
    timer:sleep(50),
    %% Aggregate results
    Results = maybe_buy_test_rcv_loop(#{}),
    %% Filter result to only find OKs and make sure we only have MAX OKs
    OK = maps:filter(fun(_K, {_, V}) -> V =:= ok end, Results),
    ?assertEqual(0, maps:size(OK)),
    %% Filter result to only find Errors and make sure we have Packets-MAX Errors
    Errors = maps:filter(
        fun(_K, {_, V}) -> V =:= {error, ?MB_BUYING_DISABLED} end,
        Results
    ),
    ?assertEqual(Packets, maps:size(Errors)),
    %% At this point a time marker should have been set in the table with that PHash
    ?assertMatch([], ets:lookup(?MB_ETS, PHash)),
    %% performance check in MICRO seconds
    TotalTime = lists:sum([T || {T, _} <- maps:values(Results)]),
    ?assert(TotalTime / Packets < ?TEST_PERF),

    ok.

test_cleanup_phash() ->
    %% Setup Max packet for device
    Max = 5,
    Packets = 100,
    lists:foreach(
        fun(_Idx) ->
            %% Populate table with a bunch of different packets and max values
            erlang:spawn(
                fun() ->
                    PHash = crypto:strong_rand_bytes(32),
                    ok = maybe_buy(PHash, Max)
                end
            )
        end,
        lists:seq(1, Packets)
    ),

    %% Wait 100ms and then run a cleanup for 10ms
    timer:sleep(100),
    Time = erlang:system_time(millisecond) - 10,
    ?assertEqual(Packets, erlang:length(select_expired(Time))),
    ok = cleanup(10),
    timer:sleep(100),
    % %% It should remove every values except the device max
    ?assertEqual(0, erlang:length(select_expired(Time))),
    ?assertEqual(0, ets:info(?MB_ETS, size)),

    ok.

maybe_buy_test_rcv_loop(Acc) ->
    receive
        {maybe_buy_test, X, Time, Result} ->
            maybe_buy_test_rcv_loop(maps:put(X, {Time, Result}, Acc))
    after ?TEST_SLEEP -> Acc
    end.

-endif.
