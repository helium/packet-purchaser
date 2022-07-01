-module(pp_http_worker).

-behavior(gen_server).

-include("config.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_packet/3
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
-define(SEND_DATA, send_data).
-define(SHUTDOWN, shutdown).
-define(SHUTDOWN_TIMEOUT, timer:seconds(5)).

-type address() :: binary().

-record(state, {
    net_id :: pp_roaming_protocol:netid_num(),
    address :: address(),
    transaction_id :: integer(),
    packets = [] :: list(pp_roaming_protocol:packet()),

    send_data_timer = 200 :: non_neg_integer(),
    send_data_timer_ref :: undefined | reference(),
    flow_type :: async | sync,
    auth_header :: null | binary(),
    protocol_version :: pv_1_0 | pv_1_1,

    should_shutdown = false :: boolean(),
    shutdown_timer_ref :: undefined | reference()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_packet(
    WorkerPid :: pid(),
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    GatewayTime :: pp_roaming_protocol:gateway_time()
) -> ok | {error, any()}.
handle_packet(Pid, SCPacket, GatewayTime) ->
    gen_server:cast(Pid, {handle_packet, SCPacket, GatewayTime}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    #{
        protocol := #http_protocol{
            endpoint = Address,
            flow_type = FlowType,
            dedupe_timeout = DedupeTimeout,
            auth_header = Auth,
            protocol_version = ProtocolVersion
        },
        net_id := NetID
    } = Args,
    lager:debug("~p init with ~p", [?MODULE, Args]),
    {ok, #state{
        net_id = NetID,
        address = Address,
        transaction_id = next_transaction_id(),
        send_data_timer = DedupeTimeout,
        flow_type = FlowType,
        auth_header = Auth,
        protocol_version = ProtocolVersion
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {handle_packet, SCPacket, GatewayTime},
    #state{send_data_timer = 0, shutdown_timer_ref = ShutdownTimerRef0} = State
) ->
    {ok, StateWithPacket} = do_handle_packet(SCPacket, GatewayTime, State),
    ok = send_data(StateWithPacket),
    {ok, ShutdownTimerRef1} = maybe_schedule_shutdown(ShutdownTimerRef0),
    {noreply, State#state{shutdown_timer_ref = ShutdownTimerRef1}};
handle_cast(
    {handle_packet, SCPacket, GatewayTime},
    #state{
        should_shutdown = false,
        send_data_timer = Timeout,
        send_data_timer_ref = TimerRef0
    } = State0
) ->
    {ok, State1} = do_handle_packet(SCPacket, GatewayTime, State0),
    {ok, TimerRef1} = maybe_schedule_send_data(Timeout, TimerRef0),
    {noreply, State1#state{send_data_timer_ref = TimerRef1}};
handle_cast(
    {handle_packet, _SCPacket, _PacketTime},
    #state{
        should_shutdown = true,
        shutdown_timer_ref = ShutdownTimerRef0,
        send_data_timer = DataTimeout
    } = State0
) ->
    lager:info("packet delivery after data sent [send_data_timer: ~p]", [DataTimeout]),
    {ok, ShutdownTimerRef1} = maybe_schedule_shutdown(ShutdownTimerRef0),
    {noreply, State0#state{shutdown_timer_ref = ShutdownTimerRef1}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?SEND_DATA, #state{} = State) ->
    ok = send_data(State),
    {ok, ShutdownTimerRef} = maybe_schedule_shutdown(undefined),
    {noreply, State#state{should_shutdown = true, shutdown_timer_ref = ShutdownTimerRef}};
handle_info(?SHUTDOWN, #state{} = State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{}) ->
    lager:info("going down ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec maybe_schedule_send_data(integer(), undefined | reference()) -> {ok, reference()}.
maybe_schedule_send_data(Timeout, undefined) ->
    {ok, erlang:send_after(Timeout, self(), ?SEND_DATA)};
maybe_schedule_send_data(_, Ref) ->
    {ok, Ref}.

-spec maybe_schedule_shutdown(undefined | reference()) -> {ok, reference()}.
maybe_schedule_shutdown(undefined) ->
    {ok, erlang:send_after(?SHUTDOWN_TIMEOUT, self(), ?SHUTDOWN)};
maybe_schedule_shutdown(CurrTimer) ->
    _ = (catch erlang:cancel_timer(CurrTimer)),
    {ok, erlang:send_after(?SHUTDOWN_TIMEOUT, self(), ?SHUTDOWN)}.

-spec next_transaction_id() -> integer().
next_transaction_id() ->
    rand:uniform(16#7FFFFFFF).

-spec do_handle_packet(
    SCPacket :: pp_roaming_protocol:sc_packet(),
    GatewayTime :: pp_roaming_protocol:gateway_time(),
    State :: #state{}
) -> {ok, #state{}}.
do_handle_packet(SCPacket, GatewayTime, #state{packets = Packets} = State) ->
    State1 = State#state{
        packets = [pp_roaming_protocol:new_packet(SCPacket, GatewayTime) | Packets]
    },
    {ok, State1}.

-spec send_data(#state{}) -> ok.
send_data(#state{
    net_id = NetID,
    address = Address,
    packets = Packets,
    transaction_id = TransactionID,
    flow_type = FlowType,
    auth_header = Auth,
    protocol_version = ProtocolVersion,
    send_data_timer = DedupWindow
}) ->
    %% NOTE: We do this here so we don't pass unnecessary things to
    %% pp_roaming_protocol.
    ok = pp_config:insert_transaction_id(TransactionID, Address, FlowType),

    Data = pp_roaming_protocol:make_uplink_payload(
        NetID,
        Packets,
        TransactionID,
        ProtocolVersion,
        DedupWindow,
        Address,
        FlowType
    ),
    Data1 = jsx:encode(Data, [{float_formatter, fun round_to_fourth_decimal/1}]),

    Headers =
        case Auth of
            null -> [{<<"Content-Type">>, <<"application/json">>}];
            _ -> [{<<"Content-Type">>, <<"application/json">>}, {<<"Authorization">>, Auth}]
        end,

    case hackney:post(Address, Headers, Data1, [with_body]) of
        {ok, 200, _Headers, <<>>} ->
            lager:info("~p empty response [flow_type: ~p]", [NetID, FlowType]),
            ok;
        {ok, 200, _Headers, Res} ->
            case FlowType of
                sync ->
                    %% All uplinks are PRStartReq. We will only ever receive a
                    %% PRStartAns from that. XMitDataReq downlinks come out of
                    %% band to the HTTP listener.
                    Decoded = jsx:decode(Res),
                    case pp_roaming_protocol:handle_prstart_ans(Decoded) of
                        {error, Err} ->
                            lager:error("error handling response: ~p", [Err]),
                            ok;
                        {join_accept, {SCPid, SCResp}} ->
                            ok = blockchain_state_channel_common:send_response(SCPid, SCResp);
                        ok ->
                            ok
                    end;
                async ->
                    ok
            end;
        {ok, Code, _Headers, Resp} ->
            lager:error("bad response: [code: ~p] [res: ~p]", [Code, Resp]),
            ok
    end.

round_to_fourth_decimal(Float) ->
    io_lib:format("~.4f", [Float]).
