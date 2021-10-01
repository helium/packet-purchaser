-module(pp_metrics).

-behaviour(gen_server).
-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

-define(ETS, pp_metrics_ets).

-define(METRIC_OFFER_COUNT, packet_purchaser_offer_count).
-define(METRIC_PACKET_COUNT, packet_purchaser_packet_count).
-define(METRIC_GWMP_COUNT, packet_purchaser_gwmp_counter).

%% gen_server API
-export([start_link/0]).

%% Prometheus API
-export([
    handle_offer/5,
    handle_packet/3,
    %% GWMP
    pull_ack/2,
    pull_ack_missed/2,
    push_ack/2,
    push_ack_missed/2
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

%% Elli API
-export([
    handle/2,
    handle_event/3
]).

-record(state, {}).

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% -------------------------------------------------------------------
%% Prometheus API Functions
%% -------------------------------------------------------------------

-spec handle_offer(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    NetID :: non_neg_integer(),
    OfferType :: join | packet,
    Action :: accepted | rejected,
    PayloadSize :: non_neg_integer()
) -> ok.
handle_offer(PubKeyBin, NetID, OfferType, Action, PayloadSize) ->
    {ok, AName} = animal_name(PubKeyBin),
    DC = calculate_dc_amount(PayloadSize),
    prometheus_counter:inc(?METRIC_OFFER_COUNT, [AName, NetID, OfferType, Action, DC]).

-spec handle_packet(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    NetID :: non_neg_integer(),
    PacketType :: join | packet
) -> ok.
handle_packet(PubKeyBin, NetID, PacketType) ->
    {ok, AName} = animal_name(PubKeyBin),
    prometheus_counter:inc(?METRIC_PACKET_COUNT, [AName, NetID, PacketType]).

-spec push_ack(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
push_ack(PubKeyBin, NetID) ->
    {ok, AName} = animal_name(PubKeyBin),
    prometheus_counter:inc(?METRIC_GWMP_COUNT, [AName, NetID, push_ack, hit]).

-spec push_ack_missed(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
push_ack_missed(PubKeyBin, NetID) ->
    {ok, AName} = animal_name(PubKeyBin),
    prometheus_counter:inc(?METRIC_GWMP_COUNT, [AName, NetID, push_ack, miss]).

-spec pull_ack(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
pull_ack(PubKeyBin, NetID) ->
    {ok, AName} = animal_name(PubKeyBin),
    prometheus_counter:inc(?METRIC_GWMP_COUNT, [AName, NetID, pull_ack, hit]).

-spec pull_ack_missed(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
pull_ack_missed(PubKeyBin, NetID) ->
    {ok, AName} = animal_name(PubKeyBin),
    prometheus_counter:inc(?METRIC_GWMP_COUNT, [AName, NetID, pull_ack, miss]).

%% -------------------------------------------------------------------
%% gen_server Callbacks
%% -------------------------------------------------------------------

init(Args) ->
    ElliOpts = [
        {callback, ?MODULE},
        {callback_args, #{forward => self()}},
        {port, proplists:get_value(port, Args, 3000)}
    ],
    {ok, _Pid} = elli:start_link(ElliOpts),

    ok = init_ets(),
    ok = declare_metrics(),

    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% elli Function Definitions
%% ------------------------------------------------------------------
handle(Req, _Args) ->
    handle(Req#req.method, elli_request:path(Req), Req).

handle('GET', [<<"metrics">>], _Req) ->
    {ok, [], prometheus_text_format:format()};
handle(_Verb, _Path, _Req) ->
    {ok, [], "Hello world"}.

handle_event(_Event, _Data, _Args) ->
    ok.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    ok.

-spec declare_metrics() -> ok.
declare_metrics() ->
    %% type = frame type :: join | packet
    %% status = bought :: accepted | rejected
    prometheus_counter:declare([
        {name, ?METRIC_OFFER_COUNT},
        {help, "Offer count for NetID"},
        {labels, [animal_name, net_id, type, status, dc]}
    ]),

    %% type = frame type :: join | packet
    prometheus_counter:declare([
        {name, ?METRIC_PACKET_COUNT},
        {help, "Packet count for NetID"},
        {labels, [animal_name, net_id, type]}
    ]),

    %% type = gwmp packet type :: push_ack | pull_ack
    %% status = received :: hit | miss
    prometheus_counter:declare([
        {name, ?METRIC_GWMP_COUNT},
        {help, "Semtech UDP acks for Gateway and NetID"},
        {labels, [animal_name, net_id, type, status]}
    ]),

    ok.

-spec animal_name(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> {ok, string()}.
animal_name(PubKeyBin) ->
    erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)).

-spec calculate_dc_amount(PayloadSize :: non_neg_integer()) ->
    failed_to_calculate_dc | non_neg_integer().
calculate_dc_amount(PayloadSize) ->
    Ledger = get_ledger(),
    case blockchain_utils:calculate_dc_amount(Ledger, PayloadSize) of
        {error, Reason} ->
            Reason;
        DCAmount ->
            DCAmount
    end.

-spec get_ledger() -> blockchain_ledger_v1:ledger().
get_ledger() ->
    Key = blockchain_ledger,
    case ets:lookup(?ETS, Key) of
        [] ->
            Ledger = blockchain:ledger(),
            true = ets:insert(?ETS, {Key, Ledger}),
            Ledger;
        [{Key, Ledger}] ->
            Ledger
    end.
