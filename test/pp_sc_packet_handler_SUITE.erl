-module(pp_sc_packet_handler_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    accept_joins_test/1,
    net_ids_env_offer_test/1,
    net_ids_map_offer_test/1,
    net_ids_map_packet_test/1,
    net_ids_env_packet_test/1,
    net_ids_no_config_test/1,
    net_ids_counter_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").

-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

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
        accept_joins_test,
        net_ids_env_offer_test,
        net_ids_map_offer_test,
        net_ids_map_packet_test,
        net_ids_env_packet_test,
        net_ids_no_config_test,
        net_ids_counter_test
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

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

accept_joins_test(_Config) ->
    SendJoinOfferFun = fun() ->
        DevNonce = crypto:strong_rand_bytes(2),
        AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Offer = join_offer(PubKeyBin, AppKey, DevNonce),
        pp_sc_packet_handler:handle_offer(Offer, self())
    end,

    %% Make sure we can accept offers
    ok = application:set_env(packet_purchaser, accept_joins, true),
    ?assertMatch(ok, SendJoinOfferFun()),
    ?assertMatch(ok, SendJoinOfferFun()),

    %% Turn it off
    ok = application:set_env(packet_purchaser, accept_joins, false),
    ?assertMatch({error, not_accepting_joins}, SendJoinOfferFun()),
    ?assertMatch({error, not_accepting_joins}, SendJoinOfferFun()),

    %% Turn it back on
    ok = application:set_env(packet_purchaser, accept_joins, true),
    ?assertMatch(ok, SendJoinOfferFun()),
    ?assertMatch(ok, SendJoinOfferFun()),

    ok.

net_ids_map_offer_test(_Config) ->
    SendPacketOfferFun = fun(NetId) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Offer = packet_offer(PubKeyBin, NetId),
        pp_sc_packet_handler:handle_offer(Offer, self())
    end,

    %% Buy all NetIDs
    ok = application:set_env(packet_purchaser, net_ids, [allow_all]),
    ?assertMatch(ok, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch(ok, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch(ok, SendPacketOfferFun(?COMCAST)),
    ?assertMatch(ok, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch(ok, SendPacketOfferFun(?ORANGE)),

    %% Reject all NetIDs
    ok = application:set_env(packet_purchaser, net_ids, #{}),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?COMCAST)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?ORANGE)),

    %% Buy Only Actility1 ID
    ok = application:set_env(packet_purchaser, net_ids, #{?ACTILITY => test}),
    ?assertMatch(ok, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?COMCAST)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?ORANGE)),

    %% Buy Multiple IDs
    ok = application:set_env(packet_purchaser, net_ids, #{?ACTILITY => test, ?ORANGE => test}),
    ?assertMatch(ok, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?COMCAST)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch(ok, SendPacketOfferFun(?ORANGE)),

    %% Buy all the IDs we know about
    ok = application:set_env(packet_purchaser, net_ids, #{
        ?EXPERIMENTAL => test,
        ?ACTILITY => test,
        ?TEKTELIC => test,
        ?ORANGE => test,
        ?COMCAST => test
    }),
    ?assertMatch(ok, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch(ok, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch(ok, SendPacketOfferFun(?COMCAST)),
    ?assertMatch(ok, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch(ok, SendPacketOfferFun(?ORANGE)),

    ok.

net_ids_env_offer_test(_Config) ->
    SendPacketOfferFun = fun(NetId) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Offer = packet_offer(PubKeyBin, NetId),
        pp_sc_packet_handler:handle_offer(Offer, self())
    end,

    %% Buy all NetIDs
    ok = application:set_env(packet_purchaser, net_ids, []),
    ?assertMatch(ok, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch(ok, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch(ok, SendPacketOfferFun(?COMCAST)),
    ?assertMatch(ok, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch(ok, SendPacketOfferFun(?ORANGE)),

    %% Buy Only Actility1 ID
    ok = application:set_env(packet_purchaser, net_ids, [?ACTILITY]),
    ?assertMatch(ok, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?COMCAST)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?ORANGE)),

    %% Buy Multiple IDs
    ok = application:set_env(packet_purchaser, net_ids, [?ACTILITY, ?ORANGE]),
    ?assertMatch(ok, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?COMCAST)),
    ?assertMatch({error, net_id_rejected}, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch(ok, SendPacketOfferFun(?ORANGE)),

    %% Buy all the IDs we know about
    ok = application:set_env(packet_purchaser, net_ids, [
        ?EXPERIMENTAL,
        ?ACTILITY,
        ?TEKTELIC,
        ?ORANGE,
        ?COMCAST
    ]),
    ?assertMatch(ok, SendPacketOfferFun(?ACTILITY)),
    ?assertMatch(ok, SendPacketOfferFun(?TEKTELIC)),
    ?assertMatch(ok, SendPacketOfferFun(?COMCAST)),
    ?assertMatch(ok, SendPacketOfferFun(?EXPERIMENTAL)),
    ?assertMatch(ok, SendPacketOfferFun(?ORANGE)),

    ok.

net_ids_map_packet_test(_Config) ->
    SendPacketFun = fun(NetId) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, NetId, 0, #{dont_encode => true}),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker(PubKeyBin),
        {state, PubKeyBin, _Socket, Address, Port, _PushData, _ScPid, _PullData, _PullDataTimer} = sys:get_state(
            Pid
        ),
        {Address, Port}
    end,

    application:set_env(packet_purchaser, net_ids, #{
        ?ACTILITY => #{address => "1.1.1.1", port => 1111},
        ?ORANGE => #{address => "2.2.2.2", port => 2222},
        ?COMCAST => #{address => "3.3.3.3", port => 3333}
    }),

    ?assertMatch({"1.1.1.1", 1111}, SendPacketFun(?ACTILITY)),
    ?assertMatch({"2.2.2.2", 2222}, SendPacketFun(?ORANGE)),
    ?assertMatch({"3.3.3.3", 3333}, SendPacketFun(?COMCAST)),
    ok.

net_ids_no_config_test(_Config) ->
    SendPacketFun = fun(NetId) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, NetId, 0, #{dont_encode => true}),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        pp_udp_sup:lookup_worker(PubKeyBin)
    end,

    application:set_env(packet_purchaser, net_ids, #{
        ?ACTILITY => #{address => "1.1.1.1", port => 1111}
        %% ?ORANGE => #{address => "2.2.2.2", port => 2222},
        %% ?COMCAST => #{address => "3.3.3.3", port => 3333}
    }),

    ?assertMatch({ok, _}, SendPacketFun(?ACTILITY)),
    ?assertMatch({error, not_found}, SendPacketFun(?ORANGE)),
    ?assertMatch({error, not_found}, SendPacketFun(?COMCAST)),

    ok.

net_ids_env_packet_test(_Config) ->
    SendPacketFun = fun(NetId) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, NetId, 0, #{dont_encode => true}),
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

    ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(?ACTILITY)),
    ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(?ORANGE)),
    ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(?COMCAST)),
    ok.

net_ids_counter_test(_Config) ->
    SendPacketFun = fun(NetId) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, NetId, 0, #{dont_encode => true}),
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

    lists:foreach(
        fun(_) -> ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(?ACTILITY)) end,
        lists:seq(1, 4)
    ),
    lists:foreach(
        fun(_) -> ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(?ORANGE)) end,
        lists:seq(1, 3)
    ),
    lists:foreach(
        fun(_) -> ?assertMatch({"1.1.1.1", 1337}, SendPacketFun(?COMCAST)) end,
        lists:seq(1, 2)
    ),

    Expected = #{?ACTILITY => 4, ?ORANGE => 3, ?COMCAST => 2},
    Actual = pp_sc_packet_handler:get_netid_packet_counts(),
    ?assertEqual(Expected, Actual),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

frame_packet(MType, PubKeyBin, NetId, FCnt, Options) ->
    NwkSessionKey = <<81, 103, 129, 150, 35, 76, 17, 164, 210, 66, 210, 149, 120, 193, 251, 85>>,
    AppSessionKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,
    DevAddr = maps:get(devaddr, Options, <<33554431:25/integer-unsigned-little, NetId:7/integer>>),
    Payload1 = frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt),

    <<DevNum:32/integer-unsigned-little>> = DevAddr,
    Routing = blockchain_helium_packet_v1:make_routing_info({devaddr, DevNum}),

    HeliumPacket = #packet_pb{
        type = lorawan,
        payload = Payload1,
        frequency = 923.3,
        datarate = maps:get(datarate, Options, <<"SF8BW125">>),
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

join_offer(PubKeyBin, AppKey, DevNonce) ->
    RoutingInfo = {eui, 1, 1},
    HeliumPacket = blockchain_helium_packet_v1:new(
        lorawan,
        join_payload(AppKey, DevNonce),
        1000,
        0,
        923.3,
        <<"SF8BW125">>,
        0.0,
        RoutingInfo
    ),

    blockchain_state_channel_offer_v1:from_packet(
        HeliumPacket,
        PubKeyBin,
        'US915'
    ).

packet_offer(PubKeyBin, NetID) ->
    DevAddr = <<33554431:25/integer-unsigned-little, NetID:7/little-unsigned-integer>>,
    NwkSessionKey = <<81, 103, 129, 150, 35, 76, 17, 164, 210, 66, 210, 149, 120, 193, 251, 85>>,
    AppSessionKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,
    FCnt = 0,

    Payload = frame_payload(?UNCONFIRMED_UP, DevAddr, NwkSessionKey, AppSessionKey, FCnt),

    <<DevNum:32/integer-unsigned-little>> = DevAddr,
    Routing = blockchain_helium_packet_v1:make_routing_info({devaddr, DevNum}),

    HeliumPacket = #packet_pb{
        type = lorawan,
        payload = Payload,
        frequency = 923.3,
        datarate = <<"SF8BW125">>,
        signal_strength = 0.0,
        snr = 0.0,
        routing = Routing
    },

    blockchain_state_channel_offer_v1:from_packet(HeliumPacket, PubKeyBin, 'US915').

join_payload(AppKey, DevNonce) ->
    MType = ?JOIN_REQ,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = reverse(?APPEUI),
    DevEUI = reverse(?DEVEUI),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:cmac(aes_cbc128, AppKey, Payload0, 4),
    <<Payload0/binary, MIC:4/binary>>.

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

%% ------------------------------------------------------------------
%% Router Utils
%% ------------------------------------------------------------------

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
