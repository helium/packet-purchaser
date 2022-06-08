-module(pp_roaming_protocol).

%% Uplinking
-export([
    make_uplink_payload/3
]).

%% Downlinking
-export([
    handle_message/1,
    handle_prstart_ans/1,
    handle_xmitdata_req/1
]).

%% Tokens
-export([
    make_uplink_token/3,
    parse_uplink_token/1
]).

-export([new_packet/2]).

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

-type pubkeybin() :: libp2p_crypto:pubkey_bin().
-type region() :: atom().
-type token() :: binary().

-define(TOKEN_SEP, <<":">>).

-record(packet, {
    sc_packet :: sc_packet(),
    gateway_time :: gateway_time(),
    location :: pp_utils:location()
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

-spec new_packet(SCPacket :: sc_packet(), GatewayTime :: gateway_time()) -> #packet{}.
new_packet(SCPacket, GatewayTime) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    #packet{
        sc_packet = SCPacket,
        gateway_time = GatewayTime,
        location = pp_utils:get_hotspot_location(PubKeyBin)
    }.

-spec make_uplink_payload(netid_num(), list(packet()), integer()) -> prstart_req().
make_uplink_payload(NetID, Uplinks, TransactionID) ->
    #packet{sc_packet = SCPacket, gateway_time = GatewayTime} = select_best(Uplinks),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PacketTime = blockchain_helium_packet_v1:timestamp(Packet),

    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
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

    Token = make_uplink_token(PubKeyBin, Region, PacketTime),
    ProtocolVersion = application:get_env(packet_purchaser, http_protocol_version, <<"1.1">>),

    #{
        'ProtocolVersion' => ProtocolVersion,
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
    | {downlink, xmitdata_ans(), downlink()}
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
    {ok, PubKeyBin, Region, PacketTime} = parse_uplink_token(Token),

    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        pp_utils:hexstring_to_binary(Payload),
        _SignalStrength = 27,
        pp_utils:uint32(PacketTime + ?JOIN1_DELAY),
        Frequency,
        pp_lorawan:index_to_datarate(Region, DR),
        rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?JOIN2_DELAY)
    ),

    SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

    case pp_roaming_downlink:lookup_handler(PubKeyBin) of
        {error, _} = Err -> Err;
        {ok, SCPid} -> {join_accept, {SCPid, SCResp}}
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
    {downlink, xmitdata_ans(), downlink()} | {error, any()}.
%% Class C ==========================================
handle_xmitdata_req(#{
    <<"MessageType">> := <<"XmitDataReq">>,
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"TransactionID">> := TransactionID,
    <<"SenderID">> := SenderID,
    <<"PHYPayload">> := Payload,
    <<"DLMetaData">> := #{
        <<"ClassMode">> := <<"C">>,
        <<"FNSULToken">> := Token,
        <<"DLFreq2">> := Frequency,
        <<"DataRate2">> := DR
    }
}) ->
    PayloadResponse = #{
        'ProtocolVersion' => ProtocolVersion,
        'MessageType' => <<"XmitDataAns">>,
        'ReceiverID' => SenderID,
        'SenderID' => <<"0xC00053">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'TransactionID' => TransactionID,
        'DLFreq2' => Frequency
    },

    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, _PacketTime} ->
            DataRate = pp_lorawan:index_to_datarate(Region, DR),

            DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
                pp_utils:hexstring_to_binary(Payload),
                _SignalStrength = 27,
                immediate,
                Frequency,
                DataRate
            ),

            SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

            case pp_roaming_downlink:lookup_handler(PubKeyBin) of
                {error, _} = Err -> Err;
                {ok, SCPid} -> {downlink, PayloadResponse, {SCPid, SCResp}}
            end
    end;
%% Class A ==========================================
handle_xmitdata_req(#{
    <<"MessageType">> := <<"XmitDataReq">>,
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"TransactionID">> := TransactionID,
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
        'TransactionID' => TransactionID,
        'DLFreq1' => Frequency1
    },

    %% Make downlink packet
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime} ->
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

            case pp_roaming_downlink:lookup_handler(PubKeyBin) of
                {error, _} = Err -> Err;
                {ok, SCPid} -> {downlink, PayloadResponse, {SCPid, SCResp}}
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

-spec make_uplink_token(pubkeybin(), region(), non_neg_integer()) -> token().
make_uplink_token(PubKeyBin, Region, PacketTime) ->
    Parts = [
        libp2p_crypto:bin_to_b58(PubKeyBin),
        erlang:atom_to_binary(Region),
        erlang:integer_to_binary(PacketTime)
    ],
    Token0 = lists:join(?TOKEN_SEP, Parts),
    Token1 = erlang:iolist_to_binary(Token0),
    pp_utils:binary_to_hexstring(Token1).

-spec parse_uplink_token(token()) ->
    {ok, pubkeybin(), region(), non_neg_integer()} | {error, any()}.
parse_uplink_token(<<"0x", Token/binary>>) ->
    parse_uplink_token(Token);
parse_uplink_token(Token) ->
    Bin = pp_utils:hex_to_binary(Token),
    case binary:split(Bin, ?TOKEN_SEP, [global]) of
        [B58, RegionBin, PacketTimeBin] ->
            PubKeyBin = libp2p_crypto:b58_to_bin(erlang:binary_to_list(B58)),
            Region = erlang:binary_to_atom(RegionBin),
            PacketTime = erlang:binary_to_integer(PacketTimeBin),
            {ok, PubKeyBin, Region, PacketTime};
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
