-module(pp_roaming_protocol).

%% Uplinking
-export([
    make_uplink_payload/7,
    select_best/1,
    gateway_time/1,
    handler_pid/1
]).

%% Downlinking
-export([
    handle_message/1,
    handle_prstart_ans/1,
    handle_xmitdata_req/1
]).

%% Tokens
-export([
    make_uplink_token/5,
    parse_uplink_token/1
]).

-export([new_packet/3]).

-define(NO_ROAMING_AGREEMENT, <<"NoRoamingAgreement">>).

-define(JOIN1_DELAY, 5_000_000).
-define(JOIN2_DELAY, 6_000_000).
-define(RX2_DELAY, 2_000_000).
-define(RX1_DELAY, 1_000_000).

%% Roaming MessageTypes
-type prstart_req() :: map().
-type prstart_ans() :: map().
-type xmitdata_req() :: map().
-type xmitdata_ans() :: map().

-type netid_num() :: non_neg_integer().
-type sc_packet() :: blockchain_state_channel_packet_v1:packet().
-type gateway_time() :: non_neg_integer().

-type downlink() :: {
    SCPid :: pid(),
    SCResp :: any()
}.

-type transaction_id() :: integer().
-type region() :: atom().
-type token() :: binary().
-type dest_url() :: binary().
-type flow_type() :: sync | async.

-define(TOKEN_SEP, <<"::">>).

-record(packet, {
    sc_packet :: sc_packet(),
    gateway_time :: gateway_time(),
    location :: pp_utils:location(),
    handler_pid :: pid()
}).
-type packet() :: #packet{}.

-export_type([
    netid_num/0,
    packet/0,
    sc_packet/0,
    gateway_time/0,
    downlink/0
]).

%% ------------------------------------------------------------------
%% Uplink
%% ------------------------------------------------------------------

-spec new_packet(SCPacket :: sc_packet(), GatewayTime :: gateway_time(), HandlerPid :: pid()) ->
    #packet{}.
new_packet(SCPacket, GatewayTime, HandlerPid) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    #packet{
        sc_packet = SCPacket,
        gateway_time = GatewayTime,
        location = pp_utils:get_hotspot_location(PubKeyBin),
        handler_pid = HandlerPid
    }.

-spec gateway_time(#packet{}) -> gateway_time().
gateway_time(#packet{gateway_time = GWTime}) ->
    GWTime.

-spec handler_pid(#packet{}) -> pid().
handler_pid(#packet{handler_pid = HandlerPid}) ->
    HandlerPid.

-spec make_uplink_payload(
    NetID :: netid_num(),
    Uplinks :: list(packet()),
    TransactionID :: integer(),
    ProtocolVersion :: pv_1_0 | pv_1_1,
    DedupWindowSize :: non_neg_integer(),
    Destination :: binary(),
    FlowType :: sync | async
) -> prstart_req().
make_uplink_payload(
    NetID,
    Uplinks,
    TransactionID,
    ProtocolVersion,
    DedupWindowSize,
    Destination,
    FlowType
) ->
    #packet{
        sc_packet = SCPacket,
        gateway_time = GatewayTime,
        handler_pid = HandlerPid
    } = select_best(Uplinks),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PacketTime = blockchain_helium_packet_v1:timestamp(Packet),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    pg:join(PubKeyBin, HandlerPid),

    RoutingInfo = blockchain_helium_packet_v1:routing_info(Packet),

    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    DataRate = blockchain_helium_packet_v1:datarate(Packet),
    Payload = blockchain_helium_packet_v1:payload(Packet),
    Frequency = blockchain_helium_packet_v1:frequency(Packet),

    {RoutingKey, RoutingValue} =
        case RoutingInfo of
            {devaddr, DevAddr} -> {'DevAddr', encode_devaddr(DevAddr)};
            {eui, DevEUI, _AppEUI} -> {'DevEUI', encode_deveui(DevEUI)}
        end,

    Token = make_uplink_token(TransactionID, Region, PacketTime, Destination, FlowType),
    ok = pp_roaming_downlink:insert_handler(TransactionID, HandlerPid),

    VersionBase =
        case ProtocolVersion of
            pv_1_0 ->
                #{'ProtocolVersion' => <<"1.0">>};
            pv_1_1 ->
                #{
                    'ProtocolVersion' => <<"1.1">>,
                    'SenderNSID' => <<"">>,
                    'DedupWindowSize' => DedupWindowSize
                }
        end,

    VersionBase#{
        'SenderID' => <<"0xC00053">>,
        'ReceiverID' => pp_utils:hexstring(NetID),
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartReq">>,
        'PHYPayload' => pp_utils:binary_to_hexstring(Payload),
        'ULMetaData' => #{
            RoutingKey => RoutingValue,
            'DataRate' => pp_lorawan:datarate_to_index(Region, DataRate),
            'ULFreq' => Frequency,
            'RecvTime' => pp_utils:format_time(GatewayTime),
            'RFRegion' => Region,
            'FNSULToken' => Token,
            'GWCnt' => erlang:length(Uplinks),
            'GWInfo' => lists:map(fun gw_info/1, Uplinks)
        }
    }.

%% ------------------------------------------------------------------
%% Downlink
%% ------------------------------------------------------------------

-spec handle_message(prstart_ans() | xmitdata_req()) ->
    ok
    | {downlink, xmitdata_ans(), downlink(), {dest_url(), flow_type()}}
    | {join_accept, downlink()}
    | {error, any()}.
handle_message(#{<<"MessageType">> := MT} = M) ->
    case MT of
        <<"PRStartAns">> ->
            handle_prstart_ans(M);
        <<"XmitDataReq">> ->
            handle_xmitdata_req(M);
        _Err ->
            throw({bad_message, M})
    end.

-spec handle_prstart_ans(prstart_ans()) -> ok | {join_accept, downlink()} | {error, any()}.
handle_prstart_ans(#{
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
    <<"MessageType">> := <<"PRStartAns">>,

    <<"PHYPayload">> := Payload,
    <<"DevEUI">> := _DevEUI,

    <<"DLMetaData">> := #{
        <<"DLFreq1">> := Frequency,
        <<"DataRate1">> := DR,
        <<"FNSULToken">> := Token
    } = DLMeta
}) ->
    {ok, TransactionID, Region, PacketTime, _, _} = parse_uplink_token(Token),

    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        pp_utils:hexstring_to_binary(Payload),
        _SignalStrength = 27,
        pp_utils:uint32(PacketTime + ?JOIN1_DELAY),
        Frequency,
        pp_lorawan:index_to_datarate(Region, DR),
        rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?JOIN2_DELAY)
    ),

    SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

    case pp_roaming_downlink:lookup_handler(TransactionID) of
        {error, _} = Err -> Err;
        {ok, SCPid} -> {join_accept, {SCPid, SCResp}}
    end;
handle_prstart_ans(#{
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
    <<"MessageType">> := <<"PRStartAns">>,

    <<"PHYPayload">> := Payload,
    <<"DevEUI">> := _DevEUI,

    <<"DLMetaData">> := #{
        <<"DLFreq2">> := Frequency,
        <<"DataRate2">> := DR,
        <<"FNSULToken">> := Token
    }
}) ->
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, TransactionID, Region, PacketTime, _, _} ->
            DataRate = pp_lorawan:index_to_datarate(Region, DR),

            DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
                pp_utils:hexstring_to_binary(Payload),
                _SignalStrength = 27,
                pp_utils:uint32(PacketTime + ?JOIN2_DELAY),
                Frequency,
                DataRate
            ),

            SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

            case pp_roaming_downlink:lookup_handler(TransactionID) of
                {error, _} = Err -> Err;
                {ok, SCPid} -> {join_accept, {SCPid, SCResp}}
            end
    end;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>}
}) ->
    ok;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := ?NO_ROAMING_AGREEMENT},
    <<"SenderID">> := SenderID
}) ->
    NetID = pp_utils:hexstring_to_int(SenderID),
    lager:info("stop buying [net_id: ~p] [reason: no roaming agreement]", [NetID]),
    pp_config:stop_buying([NetID]),
    ok;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := ResultCode} = Result,
    <<"SenderID">> := SenderID
}) ->
    %% Catchall for properly formatted messages with results we don't yet support
    lager:info(
        "[result: ~p] [sender: ~p] [description: ~p]",
        [ResultCode, SenderID, maps:get(<<"Description">>, Result, "No Description")]
    ),
    ok;
handle_prstart_ans(Res) ->
    lager:error("unrecognized prstart_ans: ~p", [Res]),
    throw({bad_response, Res}).

-spec handle_xmitdata_req(xmitdata_req()) ->
    {downlink, xmitdata_ans(), downlink(), {dest_url(), flow_type()}} | {error, any()}.
%% Class A ==========================================
handle_xmitdata_req(#{
    <<"MessageType">> := <<"XmitDataReq">>,
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"TransactionID">> := IncomingTransactionID,
    <<"SenderID">> := SenderID,
    <<"PHYPayload">> := Payload,
    <<"DLMetaData">> := #{
        <<"ClassMode">> := <<"A">>,
        <<"FNSULToken">> := Token,
        <<"DataRate1">> := DR1,
        <<"DLFreq1">> := Frequency1,
        <<"RXDelay1">> := Delay0
    } = DLMeta
}) ->
    PayloadResponse = #{
        'ProtocolVersion' => ProtocolVersion,
        'MessageType' => <<"XmitDataAns">>,
        'ReceiverID' => SenderID,
        'SenderID' => <<"0xC00053">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'TransactionID' => IncomingTransactionID,
        'DLFreq1' => Frequency1
    },

    %% Make downlink packet
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, TransactionID, Region, PacketTime, DestURL, FlowType} ->
            DataRate1 = pp_lorawan:index_to_datarate(Region, DR1),

            Delay1 =
                case Delay0 of
                    N when N < 2 -> 1;
                    N -> N
                end,

            DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
                pp_utils:hexstring_to_binary(Payload),
                _SignalStrength = 27,
                pp_utils:uint32(PacketTime + (Delay1 * ?RX1_DELAY)),
                Frequency1,
                DataRate1,
                rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?RX2_DELAY)
            ),

            SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

            case pp_roaming_downlink:lookup_handler(TransactionID) of
                {error, _} = Err -> Err;
                {ok, SCPid} -> {downlink, PayloadResponse, {SCPid, SCResp}, {DestURL, FlowType}}
            end
    end;
%% Class C ==========================================
handle_xmitdata_req(#{
    <<"MessageType">> := <<"XmitDataReq">>,
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"TransactionID">> := IncomingTransactionID,
    <<"SenderID">> := SenderID,
    <<"PHYPayload">> := Payload,
    <<"DLMetaData">> := #{
        <<"ClassMode">> := DeviceClass,
        <<"FNSULToken">> := Token,
        <<"DLFreq2">> := Frequency,
        <<"DataRate2">> := DR,
        <<"RXDelay1">> := Delay0
    }
}) ->
    PayloadResponse = #{
        'ProtocolVersion' => ProtocolVersion,
        'MessageType' => <<"XmitDataAns">>,
        'ReceiverID' => SenderID,
        'SenderID' => <<"0xC00053">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'TransactionID' => IncomingTransactionID,
        'DLFreq2' => Frequency
    },

    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, TransactionID, Region, PacketTime, DestURL, FlowType} ->
            DataRate = pp_lorawan:index_to_datarate(Region, DR),

            Delay1 =
                case Delay0 of
                    N when N < 2 -> 1;
                    N -> N
                end,

            Timeout =
                case DeviceClass of
                    <<"C">> -> immediate;
                    <<"A">> -> pp_utils:uint32(PacketTime + (Delay1 * ?RX1_DELAY) + ?RX1_DELAY)
                end,

            %% TODO: move to lora lib
            SignalStrength =
                case Region of
                    'EU868' -> 16;
                    _ -> 27
                end,

            DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
                pp_utils:hexstring_to_binary(Payload),
                SignalStrength,
                Timeout,
                Frequency,
                DataRate
            ),

            SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

            case pp_roaming_downlink:lookup_handler(TransactionID) of
                {error, _} = Err -> Err;
                {ok, SCPid} -> {downlink, PayloadResponse, {SCPid, SCResp}, {DestURL, FlowType}}
            end
    end.

rx2_from_dlmetadata(
    #{
        <<"DataRate2">> := DR,
        <<"DLFreq2">> := Frequency
    },
    PacketTime,
    Region,
    Timeout
) ->
    try pp_lorawan:index_to_datarate(Region, DR) of
        DataRate ->
            blockchain_helium_packet_v1:window(
                pp_utils:uint32(PacketTime + Timeout),
                Frequency,
                DataRate
            )
    catch
        Err ->
            lager:warning("skipping rx2, bad dr_to_datar(~p, ~p) [err: ~p]", [Region, DR, Err]),
            undefined
    end;
rx2_from_dlmetadata(_, _, _, _) ->
    lager:debug("skipping rx2, no details"),
    undefined.

%% ------------------------------------------------------------------
%% Tokens
%% ------------------------------------------------------------------

-spec make_uplink_token(transaction_id(), region(), non_neg_integer(), binary(), atom()) -> token().
make_uplink_token(TransactionID, Region, PacketTime, DestURL, FlowType) ->
    Parts = [
        erlang:integer_to_binary(TransactionID),
        erlang:atom_to_binary(Region),
        erlang:integer_to_binary(PacketTime),
        DestURL,
        erlang:atom_to_binary(FlowType)
    ],
    Token0 = lists:join(?TOKEN_SEP, Parts),
    Token1 = erlang:iolist_to_binary(Token0),
    pp_utils:binary_to_hexstring(Token1).

-spec parse_uplink_token(token()) ->
    {ok, transaction_id(), region(), non_neg_integer(), dest_url(), flow_type()} | {error, any()}.
parse_uplink_token(<<"0x", Token/binary>>) ->
    parse_uplink_token(Token);
parse_uplink_token(Token) ->
    Bin = pp_utils:hex_to_binary(Token),
    case binary:split(Bin, ?TOKEN_SEP, [global]) of
        [TransactionIDBin, RegionBin, PacketTimeBin, DestURLBin, FlowTypeBin] ->
            TransactionID = erlang:binary_to_integer(TransactionIDBin),
            Region = erlang:binary_to_atom(RegionBin),
            PacketTime = erlang:binary_to_integer(PacketTimeBin),
            FlowType = erlang:binary_to_existing_atom(FlowTypeBin),
            {ok, TransactionID, Region, PacketTime, DestURLBin, FlowType};
        _ ->
            {error, malformed_token}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec select_best(list(packet())) -> packet().
select_best(Copies) ->
    [Best | _] = lists:sort(
        fun(#packet{sc_packet = SCPacketA}, #packet{sc_packet = SCPacketB}) ->
            PacketA = blockchain_state_channel_packet_v1:packet(SCPacketA),
            PacketB = blockchain_state_channel_packet_v1:packet(SCPacketB),
            RSSIA = blockchain_helium_packet_v1:signal_strength(PacketA),
            RSSIB = blockchain_helium_packet_v1:signal_strength(PacketB),
            RSSIA > RSSIB
        end,
        Copies
    ),
    Best.

-spec gw_info(packet()) -> map().
gw_info(#packet{sc_packet = SCPacket, location = Location}) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),

    SNR = blockchain_helium_packet_v1:snr(Packet),
    RSSI = blockchain_helium_packet_v1:signal_strength(Packet),

    GW = #{
        'ID' => pp_utils:binary_to_hexstring(pp_utils:pubkeybin_to_mac(PubKeyBin)),
        'RFRegion' => Region,
        'RSSI' => erlang:trunc(RSSI),
        'SNR' => SNR,
        'DLAllowed' => true
    },
    case Location of
        {_Index, Lat, Long} ->
            GW#{'Lat' => Lat, 'Lon' => Long};
        _ ->
            GW
    end.

-spec encode_deveui(non_neg_integer()) -> binary().
encode_deveui(Num) ->
    pp_utils:hexstring(Num, 16).

-spec encode_devaddr(non_neg_integer()) -> binary().
encode_devaddr(Num) ->
    pp_utils:hexstring(Num, 8).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

encode_deveui_test() ->
    ?assertEqual(encode_deveui(0), <<"0x0000000000000000">>),
    ok.

encode_devaddr_test() ->
    ?assertEqual(encode_devaddr(0), <<"0x00000000">>),
    ok.

-endif.
