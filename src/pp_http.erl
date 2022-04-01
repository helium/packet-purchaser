-module(pp_http).

-compile([export_all, nowarn_export_all]).

-export([
    init_ets/0,
    insert_handler/2,
    delete_handler/1,
    lookup_handler/1
]).

-export([
    handle/2,
    handle_event/3
]).

-define(ETS, pp_http_ets).
-define(TOKEN_SEP, <<":">>).

%% Roaming MessageTypes
-type xmitdata_req() :: map().
-type xmitdata_ans() :: map().
-type prstart_req() :: map().
-type prstart_ans() :: map().

-type net_id() :: non_neg_integer().
-type packet() :: {
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    Location :: pp_location:location()
}.
-type downlink() :: {
    SCPid :: pid(),
    SCResp :: blockchain_state_channel_packet_v1:response()
}.

-type pubkeybin() :: libp2p_crypto:pubkey_bin().
-type region() :: atom().
-type token() :: binary().

%% Downlink Handler ==================================================

handle(Req, Args) ->
    Method = elli_request:method(Req),
    ct:pal("~p", [{Method, elli_request:path(Req), Req, Args}]),

    Body = elli_request:body(Req),
    Decoded = jsx:decode(Body),
    {ok, Response, {SCPid, SCResp}} = pp_http:handle_xmitdata_req(Decoded),
    ok = blockchain_state_channel_common:send_response(SCPid, SCResp),

    {200, [], jsx:encode(Response)}.

handle_event(_Event, _Data, _Args) ->
    ok.

%% State Channel =====================================================

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ok.

-spec insert_handler(PubKeyBin :: binary(), SCPid :: pid()) -> ok.
insert_handler(PubKeyBin, SCPid) ->
    true = ets:insert(?ETS, {PubKeyBin, SCPid}),
    ok.

-spec delete_handler(PubKeyBin :: binary()) -> ok.
delete_handler(PubKeyBin) ->
    true = ets:delete(?ETS, PubKeyBin),
    ok.

-spec lookup_handler(PubKeyBin :: binary()) -> {ok, SCPid :: pid}.
lookup_handler(PubKeyBin) ->
    [{_, SCPid}] = ets:lookup(?ETS, PubKeyBin),
    {ok, SCPid}.

%% Payload Handlers ==================================================

-spec handle_packet(net_id(), list(packet())) -> prstart_req().
handle_packet(NetID, Uplinks) ->
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
            {eui, DevEUI, _AppEUI} -> {'DevEUI', pp_utils:binary_to_hexstring(DevEUI)}
        end,

    Token = pp_http:make_uplink_token(PubKeyBin, 'US915', PacketTime),

    #{
        'ProtocolVersion' => <<"1.0">>,
        'SenderID' => <<"0xC00053">>,
        'ReceiverID' => NetID,
        'TransactionID' => 3,
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

-spec handle_prstart_ans(prstart_ans()) -> ok | {downlink, downlink()}.
handle_prstart_ans(#{
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
    <<"MessageType">> := <<"PRStartAns">>,
    <<"FNSULToken">> := Token,
    <<"DLFreq1">> := Frequency,
    <<"PHYPayload">> := Payload,
    <<"DevEUI">> := _DevEUI
}) ->
    {ok, PubKeyBin, Region, PacketTime} = pp_http:parse_uplink_token(Token),
    {ok, SCPid} = pp_http:lookup_handler(PubKeyBin),

    %% NOTE: May need to get DR from response
    DR = 0,
    DataRate = pp_lorawan:dr_to_datar(Region, DR),
    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        %% NOTE: Payload maye need to be decoded
        Payload,
        _SignalStrength = 27,
        %% FIXME: Make sure this is the correct resolution
        %% JOIN1_WINDOW pulled from lora_mac_region
        PacketTime + 5000000,
        Frequency,
        DataRate,
        _RX2 = undefined
    ),

    SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

    {downlink, {SCPid, SCResp}};
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
    <<"DevAddr">> := _
}) ->
    ok;
handle_prstart_ans(Res) ->
    throw({bad_response, Res}).

-spec handle_xmitdata_req(xmitdata_req()) -> {ok, xmitdata_ans(), downlink()}.
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
    {ok, PubKeyBin, Region, PacketTime} = ?MODULE:parse_uplink_token(Token),
    {ok, SCPid} = ?MODULE:lookup_handler(PubKeyBin),
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

    {ok, PayloadResponse, {SCPid, SCResp}}.

%% Uplinking Helpers =================================================

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

%% Tokens ============================================================

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

-spec parse_uplink_token(token()) -> {ok, pubkeybin(), region(), non_neg_integer()}.
parse_uplink_token(<<"0x", Token/binary>>) ->
    Bin = pp_utils:hex_to_binary(Token),
    [B58, RegionBin, PacketTimeBin] = binary:split(Bin, ?TOKEN_SEP, [global]),
    PubKeyBin = libp2p_crypto:b58_to_bin(erlang:binary_to_list(B58)),
    Region = erlang:binary_to_existing_atom(RegionBin),
    PacketTime = erlang:binary_to_integer(PacketTimeBin),
    {ok, PubKeyBin, Region, PacketTime}.
