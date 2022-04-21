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
    ?MB_ETS = ets:new(?MB_ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ok = scheduled_cleanup(?MB_CLEANUP),
    ok.

-spec maybe_buy_offer(
    Offer :: blockchain_state_channel_offer_v1:offer(),
    MultiBuyMax :: unlimited | non_neg_integer()
) -> ok | {error, any()}.
maybe_buy_offer(_Offer, 0) ->
    {error, ?MB_BUYING_DISABLED};
maybe_buy_offer(_Offer, unlimited) ->
    ok;
maybe_buy_offer(Offer, MultiBuyMax) ->
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),

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
