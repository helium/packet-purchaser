%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser Multi Buy ==
%% @end
%%%-------------------------------------------------------------------
-module(pp_multi_buy).

-behaviour(gen_server).
-include("packet_purchaser.hrl").

%% gen_server API
-export([start_link/0]).

%% Multi-buy API
-export([maybe_buy_offer/2]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Multi Buy
-define(MB_ETS, multi_buy_ets).
-define(MB_UNLIMITED, 9999).
-define(MB_MAX_PACKET, multi_buy_max_packet).
-define(MB_EVICT_TIMEOUT, timer:seconds(6)).
-define(MB_FUN(Hash), [
    {
        {Hash, '$1', '$2'},
        [{'=<', '$2', '$1'}],
        [{{Hash, '$1', {'+', '$2', 1}}}]
    }
]).

-define(BF_ETS, router_device_routing_bf_ets).
-define(BF_KEY, bloom_key).
%% https://hur.st/bloomfilter/?n=10000&p=1.0E-6&m=&k=20
-define(BF_UNIQ_CLIENTS_MAX, 10000).
%% -define(BF_FALSE_POS_RATE, 1.0e-6).
-define(BF_BITMAP_SIZE, 300000).
-define(BF_FILTERS_MAX, 14).
-define(BF_ROTATE_AFTER, 1000).

-record(state, {}).

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec maybe_buy_offer(blockchain_state_channel_offer_v1:offer(), non_neg_integer()) ->
    ok | {error, any()}.
maybe_buy_offer(Offer, NetID) ->
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    BFRef = lookup_bf(?BF_KEY),
    case bloom:set(BFRef, PHash) of
        false ->
            {ok, Max} = multi_buy_max_for_net_id(NetID),
            ok = schedule_clear_multi_buy(PHash),
            true = ets:insert(?MB_ETS, {PHash, Max, 1}),
            ok;
        true ->
            case ets:lookup(?MB_ETS, PHash) of
                [] ->
                    {ok, Max} = multi_buy_max_for_net_id(NetID),
                    ok = schedule_clear_multi_buy(PHash),
                    true = ets:insert(?MB_ETS, {PHash, Max, 1}),
                    ok;
                [{PHash, _Max, _Max}] ->
                    {error, ?MB_MAX_PACKET};
                [{PHash, _Max, _Curr}] ->
                    case ets:select_replace(?MB_ETS, ?MB_FUN(PHash)) of
                        0 -> {error, ?MB_MAX_PACKET};
                        1 -> ok
                    end
            end
    end.

%% -------------------------------------------------------------------
%% gen_server Callbacks
%% -------------------------------------------------------------------

init([]) ->
    ?MB_ETS = ets:new(?MB_ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ets:new(?BF_ETS, [public, named_table, set, {read_concurrency, true}]),
    {ok, BloomJoinRef} = bloom:new_forgetful(
        ?BF_BITMAP_SIZE,
        ?BF_UNIQ_CLIENTS_MAX,
        ?BF_FILTERS_MAX,
        ?BF_ROTATE_AFTER
    ),
    true = ets:insert(?BF_ETS, {?BF_KEY, BloomJoinRef}),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({multi_buy_evict, PHash}, State) ->
    true = ets:delete(?MB_ETS, PHash),
    lager:debug("cleared multi buy for ~p", [PHash]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec multi_buy_max_for_net_id(non_neg_integer()) -> {ok, non_neg_integer()}.
multi_buy_max_for_net_id(NetID) ->
    case pp_sc_packet_handler:net_id_udp_args(NetID) of
        #{multi_buy := PacketMax} ->
            {ok, PacketMax};
        _ ->
            {ok, ?MB_UNLIMITED}
    end.

-spec lookup_bf(atom()) -> reference().
lookup_bf(Key) ->
    [{Key, Ref}] = ets:lookup(?BF_ETS, Key),
    Ref.

-spec schedule_clear_multi_buy(binary()) -> ok.
schedule_clear_multi_buy(PHash) ->
    _TRef = erlang:send_after(multi_buy_eviction_timeout(), ?MODULE, {multi_buy_evict, PHash}),
    ok.

-spec multi_buy_eviction_timeout() -> non_neg_integer().
multi_buy_eviction_timeout() ->
    case application:get_env(?APP, multi_buy_eviction_timeout, ?MB_EVICT_TIMEOUT) of
        [] -> ?MB_EVICT_TIMEOUT;
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        I -> I
    end.
