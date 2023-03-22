-module(pp_packet_up).

-include("./autogen/server/packet_router_pb.hrl").

-export([
    payload/1,
    timestamp/1,
    rssi/1,
    frequency/1,
    frequency_mhz/1,
    datarate/1,
    snr/1,
    region/1,
    hold_time/1,
    gateway/1,
    signature/1,
    phash/1,
    verify/1,
    encode/1,
    decode/1,
    type/1
]).

-ifdef(TEST).

-export([
    test_new/1,
    sign/2
]).

-endif.

-define(JOIN_REQUEST, 2#000).
-define(UNCONFIRMED_UP, 2#010).
-define(CONFIRMED_UP, 2#100).

-type packet() :: #packet_router_packet_up_v1_pb{}.
-type packet_map() :: #packet_router_packet_up_v1_pb{}.
-type packet_type() ::
    {join_req, {non_neg_integer(), non_neg_integer()}}
    | {uplink, {confirmed | unconfirmed, non_neg_integer()}}
    | {undefined, any()}.

-export_type([packet/0, packet_map/0, packet_type/0]).

-spec payload(Packet :: packet()) -> binary().
payload(Packet) ->
    Packet#packet_router_packet_up_v1_pb.payload.

-spec timestamp(Packet :: packet()) -> non_neg_integer().
timestamp(Packet) ->
    Packet#packet_router_packet_up_v1_pb.timestamp.

-spec rssi(Packet :: packet()) -> integer() | undefined.
rssi(Packet) ->
    Packet#packet_router_packet_up_v1_pb.rssi.

-spec frequency(Packet :: packet()) -> non_neg_integer() | undefined.
frequency(Packet) ->
    Packet#packet_router_packet_up_v1_pb.frequency.

-spec frequency_mhz(Packet :: packet()) -> float().
frequency_mhz(Packet) ->
    Mhz = Packet#packet_router_packet_up_v1_pb.frequency / 1000000,
    list_to_float(float_to_list(Mhz, [{decimals, 4}, compact])).

-spec datarate(Packet :: packet()) -> atom().
datarate(Packet) ->
    Packet#packet_router_packet_up_v1_pb.datarate.

-spec snr(Packet :: packet()) -> float().
snr(Packet) ->
    Packet#packet_router_packet_up_v1_pb.snr.

-spec region(Packet :: packet()) -> atom().
region(Packet) ->
    Packet#packet_router_packet_up_v1_pb.region.

-spec hold_time(Packet :: packet()) -> non_neg_integer().
hold_time(Packet) ->
    Packet#packet_router_packet_up_v1_pb.hold_time.

-spec gateway(Packet :: packet()) -> binary().
gateway(Packet) ->
    Packet#packet_router_packet_up_v1_pb.gateway.

-spec signature(Packet :: packet()) -> binary().
signature(Packet) ->
    Packet#packet_router_packet_up_v1_pb.signature.

-spec phash(Packet :: packet()) -> binary().
phash(Packet) ->
    Payload = ?MODULE:payload(Packet),
    crypto:hash(sha256, Payload).

-spec verify(Packet :: packet()) -> boolean().
verify(Packet) ->
    try
        BasePacket = Packet#packet_router_packet_up_v1_pb{signature = <<>>},
        EncodedPacket = ?MODULE:encode(BasePacket),
        Signature = ?MODULE:signature(Packet),
        PubKeyBin = ?MODULE:gateway(Packet),
        PubKey = libp2p_crypto:bin_to_pubkey(PubKeyBin),
        libp2p_crypto:verify(EncodedPacket, Signature, PubKey)
    of
        Bool -> Bool
    catch
        _E:_R ->
            false
    end.

-spec encode(Packet :: packet()) -> binary().
encode(#packet_router_packet_up_v1_pb{} = Packet) ->
    packet_router_pb:encode_msg(Packet).

-spec decode(BinaryPacket :: binary()) -> packet().
decode(BinaryPacket) ->
    packet_router_pb:decode_msg(BinaryPacket, packet_router_packet_up_v1_pb).

-spec type(Packet :: packet()) -> packet_type().
type(Packet) ->
    case ?MODULE:payload(Packet) of
        <<?JOIN_REQUEST:3, _:5, AppEUI:64/integer-unsigned-little,
            DevEUI:64/integer-unsigned-little, _DevNonce:2/binary, _MIC:4/binary>> ->
            {join_req, {AppEUI, DevEUI}};
        (<<FType:3, _:5, DevAddr:32/integer-unsigned-little, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
            FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary,
            PayloadAndMIC/binary>>) when
            (FType == ?UNCONFIRMED_UP orelse FType == ?CONFIRMED_UP) andalso
                %% MIC is 4 bytes, so the binary must be at least that long
                erlang:byte_size(PayloadAndMIC) >= 4
        ->
            Body = binary:part(PayloadAndMIC, {0, byte_size(PayloadAndMIC) - 4}),
            FPort =
                case Body of
                    <<>> -> undefined;
                    <<Port:8, _Payload/binary>> -> Port
                end,
            case FPort of
                0 when FOptsLen /= 0 ->
                    {undefined, FType};
                _ ->
                    case FType of
                        ?CONFIRMED_UP -> {uplink, {confirmed, DevAddr}};
                        ?UNCONFIRMED_UP -> {uplink, {unconfirmed, DevAddr}}
                    end
            end;
        <<FType:3, _/bitstring>> ->
            {undefined, FType};
        _ ->
            {undefined, 0}
    end.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(Opts :: map()) -> packet().
test_new(Opts) ->
    #packet_router_packet_up_v1_pb{
        payload = maps:get(payload, Opts, <<"payload">>),
        timestamp = maps:get(timestamp, Opts, erlang:system_time(millisecond)),
        rssi = maps:get(rssi, Opts, -40),
        frequency = maps:get(frequency, Opts, 904_300_000),
        datarate = maps:get(datarate, Opts, 'SF7BW125'),
        snr = maps:get(snr, Opts, 7.0),
        region = maps:get(region, Opts, 'US915'),
        hold_time = maps:get(hold_time, Opts, 0),
        gateway = maps:get(gateway, Opts, <<"gateway">>),
        signature = maps:get(signature, Opts, <<"signature">>)
    }.

-spec sign(Packet :: packet(), SigFun :: fun()) -> packet().
sign(Packet, SigFun) ->
    PacketEncoded = ?MODULE:encode(Packet#packet_router_packet_up_v1_pb{
        signature = <<>>
    }),
    Packet#packet_router_packet_up_v1_pb{
        signature = SigFun(PacketEncoded)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

payload_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(<<"payload">>, payload(PacketUp)),
    ok.

timestamp_test() ->
    Now = erlang:system_time(millisecond),
    PacketUp = ?MODULE:test_new(#{timestamp => Now}),
    ?assertEqual(Now, timestamp(PacketUp)),
    ok.

rssi_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(-40, rssi(PacketUp)),
    ok.

frequency_mhz_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(904.30, frequency_mhz(PacketUp)),
    ok.

datarate_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual('SF7BW125', datarate(PacketUp)),
    ok.

snr_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(7.0, snr(PacketUp)),
    ok.

region_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual('US915', region(PacketUp)),
    ok.

hold_time_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(0, hold_time(PacketUp)),
    ok.

gateway_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(<<"gateway">>, gateway(PacketUp)),
    ok.

signature_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(<<"signature">>, signature(PacketUp)),
    ok.

verify_test() ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    PacketUp = ?MODULE:test_new(#{gateway => Gateway}),
    SignedPacketUp = ?MODULE:sign(PacketUp, SigFun),

    ?assert(verify(SignedPacketUp)),
    ok.

encode_decode_test() ->
    PacketUp = ?MODULE:test_new(#{frequency => 904_000_000}),
    ?assertEqual(PacketUp, decode(encode(PacketUp))),
    ok.

type_test() ->
    ?assertEqual(
        {join_req, {1, 1}},
        ?MODULE:type(
            ?MODULE:test_new(#{
                payload =>
                    <<
                        (?JOIN_REQUEST):3,
                        0:3,
                        1:2,
                        1:64/integer-unsigned-little,
                        1:64/integer-unsigned-little,
                        (crypto:strong_rand_bytes(2))/binary,
                        (crypto:strong_rand_bytes(4))/binary
                    >>
            })
        )
    ),
    UnconfirmedUp = ?UNCONFIRMED_UP,
    ?assertEqual(
        {uplink, {unconfirmed, 1}},
        ?MODULE:type(
            ?MODULE:test_new(#{
                payload =>
                    <<UnconfirmedUp:3, 0:3, 1:2, 16#00000001:32/integer-unsigned-little, 0:1, 0:1,
                        0:1, 0:1, 1:4, 2:16/little-unsigned-integer,
                        (crypto:strong_rand_bytes(1))/binary, 2:8/integer,
                        (crypto:strong_rand_bytes(20))/binary>>
            })
        )
    ),
    ConfirmedUp = ?CONFIRMED_UP,
    ?assertEqual(
        {uplink, {confirmed, 1}},
        ?MODULE:type(
            ?MODULE:test_new(#{
                payload =>
                    <<ConfirmedUp:3, 0:3, 1:2, 16#00000001:32/integer-unsigned-little, 0:1, 0:1,
                        0:1, 0:1, 1:4, 2:16/little-unsigned-integer,
                        (crypto:strong_rand_bytes(1))/binary, 2:8/integer,
                        (crypto:strong_rand_bytes(20))/binary>>
            })
        )
    ),
    ?assertEqual(
        {undefined, 7},
        ?MODULE:type(
            ?MODULE:test_new(#{payload => <<2#111:3, (crypto:strong_rand_bytes(20))/binary>>})
        )
    ),
    ?assertEqual({undefined, 0}, ?MODULE:type(?MODULE:test_new(#{payload => <<>>}))),
    ok.

-endif.
