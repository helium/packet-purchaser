-module(pp_metrics_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([net_ids_counter_test/1, location_counter_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").

%% NetIDs
-define(ACTILITY, 16#000002).
-define(COMCAST, 16#000022).
-define(EXPERIMENTAL, 16#000000).
-define(ORANGE, 16#00000F).
-define(TEKTELIC, 16#000037).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        net_ids_counter_test,
        location_counter_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

location_counter_test(_Config) ->
    SendPacketFun = fun(DevAddr, PubKeyBins) ->
        lists:foreach(
            fun(PubKeyBin) ->
                Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{dont_encode => true}),
                pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self())
            end,
            PubKeyBins
        )
    end,

    ActilityDevAddr = pp_utils:hex_to_binary(<<"04ABCDEF">>),
    OrangeDevAddr = pp_utils:hex_to_binary(<<"1E123456">>),
    ComcastDevAddr = pp_utils:hex_to_binary(<<"45000042">>),

    SendPacketFun(
        ActilityDevAddr,
        [
            %% {US, FL, Winter Haven}
            libp2p_crypto:b58_to_bin("1129zHtCXModu3mzP98TMCs63WZnm2xGT3WHQQbmizgEmqWQw9Vd"),
            %% {US, CA, Bloomington}
            libp2p_crypto:b58_to_bin("112goQHPf921bTU2c46zSvETfLqcdT1RQwvX9NDucHHBVrEMJuBp"),
            %% {CA, BC, Burnaby}
            libp2p_crypto:b58_to_bin("112s3a4PkmZZt3F9qD1nhrF643D8uaY4dwmznyRKMpXkcsAWrnkF")
        ]
    ),
    SendPacketFun(
        OrangeDevAddr,
        [
            %% {US, FL, Winter Haven}
            libp2p_crypto:b58_to_bin("1129zHtCXModu3mzP98TMCs63WZnm2xGT3WHQQbmizgEmqWQw9Vd"),
            %% {US, CA, Bloomington}
            libp2p_crypto:b58_to_bin("112goQHPf921bTU2c46zSvETfLqcdT1RQwvX9NDucHHBVrEMJuBp")
        ]
    ),
    SendPacketFun(
        ComcastDevAddr,
        [
            %% {US, FL, Winter Haven}
            libp2p_crypto:b58_to_bin("1129zHtCXModu3mzP98TMCs63WZnm2xGT3WHQQbmizgEmqWQw9Vd")
        ]
    ),

    timer:sleep(timer:seconds(2)),

    Expected = #{
        {<<"United States">>, <<"Florida">>, <<"Winter Haven">>} => 3,
        {<<"United States">>, <<"California">>, <<"Bloomington">>} => 2,
        {<<"Canada">>, <<"British Columbia">>, <<"Burnaby">>} => 1
    },
    Actual = pp_metrics:get_location_packet_counts(),
    ?assertEqual(Expected, Actual),

    ok.

net_ids_counter_test(_Config) ->
    SendPacketFun = fun(DevAddr) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{dont_encode => true}),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker(PubKeyBin),
        {state, PubKeyBin, _Socket, Address, Port, _PushData, _ScPid, _PullData, _PullDataTimer} = sys:get_state(
            Pid
        ),
        {Address, Port}
    end,

    application:set_env(packet_purchaser, net_ids, [?ACTILITY, ?ORANGE, ?COMCAST]),
    application:set_env(packet_purchaser, pp_udp_worker, [
        {address, "1.1.1.1"},
        {port, 1337}
    ]),

    true = ets:delete_all_objects(pp_net_id_packet_count),

    ActilityDevAddr = pp_utils:hex_to_binary(<<"04ABCDEF">>),
    lists:foreach(
        fun(_) -> ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(ActilityDevAddr)) end,
        lists:seq(1, 4)
    ),
    OrangeDevAddr = pp_utils:hex_to_binary(<<"1E123456">>),
    lists:foreach(
        fun(_) -> ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(OrangeDevAddr)) end,
        lists:seq(1, 3)
    ),
    ComcastDevAddr = pp_utils:hex_to_binary(<<"45000042">>),
    lists:foreach(
        fun(_) -> ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(ComcastDevAddr)) end,
        lists:seq(1, 2)
    ),

    Expected = #{?ACTILITY => 4, ?ORANGE => 3, ?COMCAST => 2},
    Actual = pp_metrics:get_netid_packet_counts(),
    ?assertEqual(Expected, Actual),
    ok.

%% -------------------------------------------------------------------
%% Utils
%% -------------------------------------------------------------------

frame_packet(MType, PubKeyBin, DevAddr, FCnt, Options) ->
    NwkSessionKey = <<81, 103, 129, 150, 35, 76, 17, 164, 210, 66, 210, 149, 120, 193, 251, 85>>,
    AppSessionKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,
    Payload1 = frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt),

    <<DevNum:32/integer-unsigned>> = DevAddr,
    Routing = blockchain_helium_packet_v1:make_routing_info({devaddr, DevNum}),

    HeliumPacket = #packet_pb{
        type = lorawan,
        payload = Payload1,
        frequency = 923.3,
        datarate = maps:get(datarate, Options, "SF8BW125"),
        signal_strength = maps:get(rssi, Options, 0.0),
        snr = maps:get(snr, Options, 0.0),
        routing = Routing
    },
    Packet = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket,
        hotspot = PubKeyBin,
        region = 'US915'
    },
    case maps:get(dont_encode, Options, false) of
        true ->
            Packet;
        false ->
            Msg = #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}},
            blockchain_state_channel_v1_pb:encode_msg(Msg)
    end.

frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt) ->
    MHDRRFU = 0,
    Major = 0,
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FOptsBin = <<>>,
    FOptsLen = byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = <<1:8>>,
    Data = reverse(
        cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)
    ),
    FCntSize = 16,
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
            FOptsLen:4, FCnt:FCntSize/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:cmac(aes_cbc128, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    <<Payload0/binary, MIC:4/binary>>.

-spec b0(integer(), binary(), integer(), integer()) -> binary().
b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

%% ------------------------------------------------------------------
%% Lorawan Utils
%% ------------------------------------------------------------------

reverse(Bin) -> reverse(Bin, <<>>).

reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) -> reverse(Rest, <<H/binary, Acc/binary>>).

cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I + 1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) ->
    Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

-spec ai(integer(), binary(), integer(), integer()) -> binary().
ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

-spec binxor(binary(), binary(), binary()) -> binary().
binxor(<<>>, <<>>, Acc) ->
    Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).
