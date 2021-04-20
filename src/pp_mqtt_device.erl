-module(pp_mqtt_device).

-behaviour(gen_server).

-include_lib("gw.hrl").

%% API
-export([start_link/0, join/1, uplink/1, defaults/0, update/2, reset_defaults/1]).

-export([activate/1, deactivate/1]).

-export([handle_downlink/2, make_join_payload/3]).

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
    mqtt,
    dev_eui,
    join_eui,
    app_key,
    uplink_interval,
    uplink_count,
    confirmed,
    payload,
    f_port,
    dev_addr,
    dev_nonce,
    f_cnt_up,
    f_cnt_down,
    app_s_key,
    nwk_s_key,
    state = otaa :: otaa | activated,
    gateway,
    otaa_delay,
    context
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link(?MODULE, [], []).

join(Pid) ->
    gen_server:cast(Pid, join).

uplink(Pid) ->
    gen_server:cast(Pid, uplink).

activate(Pid) ->
    gen_server:cast(Pid, {update, [{state, activated}]}).

deactivate(Pid) ->
    gen_server:cast(Pid, {update, [{state, otaa}]}).

handle_downlink(Pid, Downlink) ->
    gen_server:cast(Pid, {downlink, Downlink}).

update(Pid, Opts) ->
    gen_server:cast(Pid, {update, Opts}).

defaults() ->
    [
        {dev_eui, <<"a5e802b270dd196e">>},
        {gateway, <<"c360747576ca24e2">>},
        {dev_nonce, dev_nonce()},
        {app_key, <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
        {context, <<1, 2, 3, 4>>}
    ].

reset_defaults(Pid) ->
    ?MODULE:update(Pid, ?MODULE:defaults()).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    Device = update_device(defaults(), #state{}),

    {ok, Pid} = emqtt:start_link(),
    {ok, _} = emqtt:connect(Pid),
    timer:apply_interval(10000, emqtt, ping, [Pid]),

    GatewayTopic = <<"gateway/", (Device#state.gateway)/binary, "/#">>,
    lager:info("Subcribing to ~p", [GatewayTopic]),
    emqtt:subscribe(Pid, #{}, [{GatewayTopic, []}]),

    {ok, Device#state{mqtt = Pid}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({downlink, Downlink}, State) ->
    case is_downlink_for_current_context(Downlink, State) of
        true ->
            ok = ack_to_downlink(Downlink, State);
        false ->
            lager:debug("Another device is on our gateway~n")
    end,
    {noreply, State};
handle_cast(join, Device) ->
    ok = do_join(Device),
    {noreply, Device#state{dev_nonce = dev_nonce()}};
handle_cast(uplink, Device) ->
    ok = do_uplink(Device),
    {noreply, Device#state{dev_nonce = dev_nonce()}};
handle_cast({update, Opts}, Device) ->
    {noreply, update_device(Opts, Device)};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({publish, #{topic := Topic, payload := Payload}}, State) ->
    ?MODULE:activate(self()),

    case gw:decode_msg(Payload, 'gw.DownlinkFrame') of
        #'gw.DownlinkFrame'{} = DF ->
            [Action | _] = lists:reverse(binary:split(Topic, <<"/">>, [global])),
            case erlang:binary_to_atom(Action, utf8) of
                down -> ?MODULE:handle_downlink(self(), DF);
                _ -> ok
            end;
        _ ->
            lager:warning("Could not decode message")
    end,

    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

ack_to_downlink(
    #'gw.DownlinkFrame'{token = Token, downlink_id = DownlinkID},
    #state{mqtt = Pid, gateway = Gateway}
) ->
    Topic = ack_topic(Gateway),
    AckPayload = make_ack(Token, DownlinkID, Gateway),
    CPBin = gw:encode_msg(AckPayload),

    lager:info(
        "~n~n-----------> Sending~n"
        "Topic : ~p~n"
        "Payload : ~p~n"
        "CPBin: ~p~n~n",
        [Topic, AckPayload, CPBin]
    ),

    emqtt:publish(Pid, Topic, #{}, CPBin, []).

do_join(#state{app_key = undefined}) ->
    lager:warning("Please set an AppKey and other device details first~n"),
    ok;
do_join(#state{mqtt = Pid, state = otaa, gateway = GatewayID, context = Ctx} = Device) ->
    PhyPayload = make_join_payload(Device),
    Topic = join_topic(GatewayID),
    Frame = make_chirpstack_frame(PhyPayload, GatewayID, Ctx),
    CPBin = gw:encode_msg(Frame),

    lager:info(
        "~n~n-----------> Sending~n"
        "Topic : ~p~n"
        "Payload : ~p~n"
        "CPBin: ~p~n~n",
        [Topic, PhyPayload, CPBin]
    ),

    emqtt:publish(Pid, Topic, #{}, CPBin, []).

do_uplink(#state{app_key = undefined}) ->
    lager:warning("Please set an AppKey and other device details first~n"),
    ok;
do_uplink(#state{mqtt = Pid, gateway = GatewayID, context = Ctx}) ->
    %% Fake payload lifted from somewhere
    PhyPayload = <<128, 88, 5, 127, 1, 0, 0, 0, 10, 26, 91, 125, 213, 173, 91, 75>>,
    Topic = uplink_topic(GatewayID),
    Frame = make_chirpstack_frame(PhyPayload, GatewayID, Ctx),
    CPBin = gw:encode_msg(Frame),

    lager:info(
        "~n~n-----------> Sending~n"
        "Topic : ~p~n"
        "Payload : ~p~n"
        "CPBin: ~p~n~n",
        [Topic, PhyPayload, CPBin]
    ),

    emqtt:publish(Pid, Topic, #{}, CPBin, []).

make_join_payload(#state{
    app_key = AppKey,
    dev_eui = DevEUI0,
    dev_nonce = DevNonce
}) ->
    semtech_udp:make_join_payload(AppKey, DevEUI0, DevNonce).

uplink_topic(GatewayID) ->
    <<"gateway/", GatewayID/binary, "/event/up">>.

join_topic(GatewayID) ->
    <<"gateway/", GatewayID/binary, "/event/up">>.

ack_topic(GatewayID) ->
    <<"gateway/", GatewayID/binary, "/event/ack">>.

dev_nonce() ->
    crypto:strong_rand_bytes(2).

is_downlink_for_current_context(
    #'gw.DownlinkFrame'{tx_info = #'gw.DownlinkTXInfo'{context = Context}},
    #state{context = Context}
) ->
    true;
is_downlink_for_current_context(_, _) ->
    false.

update_device([], D) ->
    D;
update_device([{context, Context} | T], D) ->
    update_device(T, D#state{context = Context});
update_device([{state, State} | T], D) ->
    case State of
        otaa -> lager:info("Device is inactive");
        activated -> lager:info("Device is actiive")
    end,
    update_device(T, D#state{state = State});
update_device([{app_key, AppKey} | T], D) ->
    update_device(T, D#state{app_key = AppKey});
update_device([{dev_eui, DevEUI} | T], D) ->
    update_device(T, D#state{dev_eui = DevEUI});
update_device([{dev_nonce, DevNonce} | T], D) ->
    update_device(T, D#state{dev_nonce = DevNonce});
update_device([{join_eui, JoinEUI} | T], D) ->
    update_device(T, D#state{join_eui = JoinEUI});
update_device([{otaa_delay, Delay} | T], D) ->
    update_device(T, D#state{otaa_delay = Delay});
update_device([{uplink_interval, Interval} | T], D) ->
    update_device(T, D#state{uplink_interval = Interval});
update_device([{uplink_count, Count} | T], D) ->
    update_device(T, D#state{uplink_count = Count});
update_device([{uplink_payload, Confirmed, Port, Payload} | T], D) ->
    update_device(T, D#state{f_port = Port, confirmed = Confirmed, payload = Payload});
update_device([{gateway, Gateway} | T], D) ->
    update_device(T, D#state{gateway = Gateway}).

make_chirpstack_frame(Payload, GatewayID, Context) ->
    UplinkID = uuid_v4(),
    #'gw.UplinkFrame'{
        phy_payload = Payload,
        tx_info = #'gw.UplinkTXInfo'{
            frequency = 868100000,
            modulation = 'LORA',
            modulation_info =
                {lora_modulation_info, #'gw.LoRaModulationInfo'{
                    bandwidth = 125,
                    spreading_factor = 7,
                    code_rate = "3/4",
                    polarization_inversion = false
                }}
        },
        rx_info = #'gw.UplinkRXInfo'{
            gateway_id = pp_utils:hex_to_bin(GatewayID),
            %% time = undefined,
            %% time_since_gps_epoch = erlang:system_time(millisecond),
            rssi = -50,
            lora_snr = 5.5,
            channel = 0,
            rf_chain = 0,
            board = 0,
            antenna = 0,
            %% location = undefined,
            fine_timestamp_type = 'NONE',
            fine_timestamp = undefined,
            context = Context,
            uplink_id = UplinkID,
            crc_status = 'NO_CRC'
        }
    }.

make_ack(Token, DownlinkID, GatewayID) ->
    #'gw.DownlinkTXAck'{
        gateway_id = pp_utils:hex_to_bin(GatewayID),
        token = Token,
        error = [],
        downlink_id = DownlinkID,
        items = []
    }.

uuid_v4() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    Str = io_lib:format(
        "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]
    ),
    erlang:list_to_binary(Str).
