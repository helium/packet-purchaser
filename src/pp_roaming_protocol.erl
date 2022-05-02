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

%% Roaming MessageTypes
-type prstart_req() :: map().
-type prstart_ans() :: map().
-type xmitdata_req() :: map().
-type xmitdata_ans() :: map().

-type netid_num() :: non_neg_integer().
%% -type net_id() :: binary().
-type sc_packet() :: blockchain_state_channel_packet_v1:packet().
-type packet_time() :: non_neg_integer().
-type packet() :: {
    SCPacket :: sc_packet(),
    PacketTime :: packet_time(),
    Location :: pp_utils:location()
}.

-type downlink() :: {
    SCPid :: pid(),
    SCResp :: any()
}.

-type pubkeybin() :: libp2p_crypto:pubkey_bin().
-type region() :: atom().
-type token() :: binary().

-define(TOKEN_SEP, <<":">>).

-export_type([
    netid_num/0,
    packet/0,
    sc_packet/0,
    packet_time/0,
    downlink/0
]).

%% ------------------------------------------------------------------
%% Uplink
%% ------------------------------------------------------------------

-spec make_uplink_payload(netid_num(), list(packet()), integer()) -> prstart_req().
make_uplink_payload(NetID, Uplinks, TransactionID) ->
    {SCPacket, PacketTime, _} = select_best(Uplinks),

    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    RoutingInfo = blockchain_helium_packet_v1:routing_info(Packet),

    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    DataRate = blockchain_helium_packet_v1:datarate(Packet),
    Payload = blockchain_helium_packet_v1:payload(Packet),
    Frequency = blockchain_helium_packet_v1:frequency(Packet),

    {RoutingKey, RoutingValue} =
        case RoutingInfo of
            {devaddr, DevAddr} -> {'DevAddr', pp_utils:binary_to_hexstring(DevAddr)};
            {eui, DevEUI, _AppEUI} -> {'DevEUI', pp_utils:hexstring(DevEUI)}
        end,

    Token = make_uplink_token(PubKeyBin, Region, PacketTime),

    #{
        'ProtocolVersion' => <<"1.0">>,
        'SenderID' => <<"0xC00053">>,
        'ReceiverID' => pp_utils:hexstring(NetID),
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartReq">>,
        'PHYPayload' => pp_utils:binary_to_hexstring(Payload),
        'ULMetaData' => #{
            RoutingKey => RoutingValue,
            'DataRate' => pp_lorawan:datar_to_dr(Region, DataRate),
            'ULFreq' => Frequency,
            'RecvTime' => pp_utils:format_time(PacketTime),
            'RFRegion' => Region,
            'FNSULToken' => Token,
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
    }
}) ->
    {ok, PubKeyBin, Region, PacketTime} = parse_uplink_token(Token),

    DataRate = pp_lorawan:dr_to_datar(Region, DR),
    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        %% NOTE: Testing encoding
        pp_utils:hexstring_to_binary(Payload),
        _SignalStrength = 27,
        %% FIXME: Make sure this is the correct resolution
        %% JOIN1_WINDOW pulled from lora_mac_region
        (PacketTime + 5000000) band 16#FFFFFFFF,
        Frequency,
        erlang:binary_to_list(DataRate)
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
handle_prstart_ans(Res) ->
    throw({bad_response, Res}).

-spec handle_xmitdata_req(xmitdata_req()) ->
    {downlink, xmitdata_ans(), downlink()} | {error, any()}.
handle_xmitdata_req(XmitDataReq) ->
    #{
        <<"MessageType">> := <<"XmitDataReq">>,
        <<"TransactionID">> := TransactionID,
        <<"SenderID">> := SenderID,
        <<"PHYPayload">> := Payload,
        <<"DLMetaData">> := #{
            <<"FNSULToken">> := Token,
            <<"DataRate1">> := DR,
            <<"DLFreq1">> := Frequency,
            <<"RXDelay1">> := Delay
            %% <<"GWInfo">> := [#{<<"ULToken">> := _ULToken}]
        }
    } = XmitDataReq,
    PayloadResponse = #{
        'ProtocolVersion' => <<"1.0">>,
        'MessageType' => <<"XmitDataAns">>,
        'ReceiverID' => SenderID,
        'SenderID' => <<"0xC00053">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'TransactionID' => TransactionID,
        'DLFreq1' => Frequency
    },

    %% Make downlink packet
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime} ->
            DataRate = pp_lorawan:dr_to_datar(Region, DR),
            DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
                base64:decode(pp_utils:hexstring_to_binary(Payload)),
                _SignalStrength = 27,
                %% FIXME: Make sure this is the correct resolution
                PacketTime + Delay,
                Frequency,
                DataRate,
                _RX2 = undefined
            ),
            SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

            case pp_roaming_downlink:lookup_handler(PubKeyBin) of
                {error, _} = Err -> Err;
                {ok, SCPid} -> {downlink, PayloadResponse, {SCPid, SCResp}}
            end
    end.

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
    Bin = pp_utils:hex_to_binary(Token),
    case binary:split(Bin, ?TOKEN_SEP, [global]) of
        [B58, RegionBin, PacketTimeBin] ->
            PubKeyBin = libp2p_crypto:b58_to_bin(erlang:binary_to_list(B58)),
            Region = erlang:binary_to_existing_atom(RegionBin),
            PacketTime = erlang:binary_to_integer(PacketTimeBin),
            {ok, PubKeyBin, Region, PacketTime};
        _ ->
            {error, malformed_token}
    end;
parse_uplink_token(_) ->
    {error, malformed_token}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec select_best(list(packet())) -> packet().
select_best(Copies) ->
    [Best | _] = lists:sort(
        fun({SCPacketA, _, _}, {SCPacketB, _, _}) ->
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
gw_info({SCPacket, _PacketTime, Location}) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),

    SNR = blockchain_helium_packet_v1:snr(Packet),
    RSSI = blockchain_helium_packet_v1:signal_strength(Packet),

    GW = #{
        'ID' => pp_utils:binary_to_hexstring(pp_utils:pubkeybin_to_mac(PubKeyBin)),
        'RFRegion' => Region,
        'RSSI' => RSSI,
        'SNR' => SNR,
        'DLAllowed' => true
    },
    case Location of
        {_Index, Lat, Long} ->
            GW#{'Lat' => Lat, 'Lon' => Long};
        _ ->
            GW
    end.
