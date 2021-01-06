-module(packet_purchaser_udp_worker_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("packet_purchaser.hrl").
-include("semtech_udp.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    push_data/1,
    delay_push_data/1,
    pull_data/1,
    failed_pull_data/1,
    pull_resp/1,
    multi_hotspots/1
]).

-record(state, {
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    socket :: gen_udp:socket(),
    address :: inet:socket_address() | inet:hostname(),
    port :: inet:port_number(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    sc_pid :: undefined | pid(),
    pull_data :: {reference(), binary()} | undefined,
    pull_data_timer :: non_neg_integer()
}).

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
    [push_data, delay_push_data, pull_data, failed_pull_data, pull_resp, multi_hotspots].

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

push_data(Config) ->
    FakeLNSPid = proplists:get_value(fake_lns, Config),
    {PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    Payload = <<"payload">>,
    Timestamp = erlang:system_time(millisecond),
    RSSI = -80.0,
    Frequency = 904.299,
    DataRate = "SF10BW125",
    SNR = 6.199,
    Packet = blockchain_helium_packet_v1:new(
        lorawan,
        Payload,
        Timestamp,
        RSSI,
        Frequency,
        DataRate,
        SNR,
        {devaddr, 16#deadbeef}
    ),
    Region = 'US915',
    SCPacket = blockchain_state_channel_packet_v1:new(
        Packet,
        PubKeyBin,
        Region
    ),

    ok = packet_purchaser_sc_packet_handler:handle_packet(
        SCPacket,
        erlang:system_time(millisecond),
        self()
    ),

    {ok, Map0} = fake_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(Payload),
                        <<"datr">> => DataRate,
                        <<"freq">> => Frequency,
                        <<"rfch">> => 0,
                        <<"lsnr">> => SNR,
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(RSSI),
                        <<"size">> => erlang:byte_size(Payload),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(Timestamp / 1000)
                    }
                ]
            },
            Map0
        )
    ),

    %% Chekcing that the push data cache is empty as we should have gotten the push ack
    test_utils:wait_until(fun() ->
        State = sys:get_state(WorkerPid),
        State#state.push_data == #{} andalso self() == State#state.sc_pid
    end),

    ok.

delay_push_data(Config) ->
    FakeLNSPid = proplists:get_value(fake_lns, Config),
    {PubKeyBin, _WorkerPid} = proplists:get_value(gateway, Config),

    Payload = <<"payload">>,
    Timestamp = erlang:system_time(millisecond),
    RSSI = -80.0,
    Frequency = 904.299,
    DataRate = "SF10BW125",
    SNR = 6.199,
    Packet = blockchain_helium_packet_v1:new(
        lorawan,
        Payload,
        Timestamp,
        RSSI,
        Frequency,
        DataRate,
        SNR,
        {devaddr, 16#deadbeef}
    ),
    Region = 'US915',
    SCPacket = blockchain_state_channel_packet_v1:new(
        Packet,
        PubKeyBin,
        Region
    ),

    ok = packet_purchaser_sc_packet_handler:handle_packet(
        SCPacket,
        erlang:system_time(millisecond),
        self()
    ),

    {ok, Map0} = fake_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(Payload),
                        <<"datr">> => DataRate,
                        <<"freq">> => Frequency,
                        <<"rfch">> => 0,
                        <<"lsnr">> => SNR,
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(RSSI),
                        <<"size">> => erlang:byte_size(Payload),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(Timestamp / 1000)
                    }
                ]
            },
            Map0
        )
    ),

    ok = fake_lns:delay_next_udp(FakeLNSPid, timer:seconds(3)),
    ok = packet_purchaser_sc_packet_handler:handle_packet(
        SCPacket,
        erlang:system_time(millisecond),
        self()
    ),

    {ok, Map1} = fake_lns:rcv(FakeLNSPid, ?PUSH_DATA, timer:seconds(4)),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(Payload),
                        <<"datr">> => DataRate,
                        <<"freq">> => Frequency,
                        <<"rfch">> => 0,
                        <<"lsnr">> => SNR,
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(RSSI),
                        <<"size">> => erlang:byte_size(Payload),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(Timestamp / 1000)
                    }
                ]
            },
            Map1
        )
    ),
    ok.

pull_data(Config) ->
    FakeLNSPid = proplists:get_value(fake_lns, Config),
    {PubKeyBin, _WorkerPid} = proplists:get_value(gateway, Config),

    {ok, {Token, MAC}} = fake_lns:rcv(FakeLNSPid, ?PULL_DATA, timer:seconds(5)),
    ?assert(erlang:is_binary(Token)),
    ?assertEqual(packet_purchaser_utils:pubkeybin_to_mac(PubKeyBin), MAC),
    ok.

failed_pull_data(Config) ->
    FakeLNSPid = proplists:get_value(fake_lns, Config),
    {_PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    Ref = erlang:monitor(process, WorkerPid),
    ok = fake_lns:delay_next_udp(FakeLNSPid, timer:seconds(5)),

    receive
        {'DOWN', Ref, process, WorkerPid, pull_data_timeout} ->
            true;
        Msg ->
            ct:fail("received unexpected message ~p", [Msg])
    after 5000 -> ct:fail("down timeout")
    end,

    ok.

pull_resp(Config) ->
    FakeLNSPid = proplists:get_value(fake_lns, Config),
    {PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    Payload = <<"payload">>,
    Timestamp = erlang:system_time(millisecond),
    RSSI = -80.0,
    Frequency = 904.299,
    DataRate = "SF10BW125",
    SNR = 6.199,
    Packet = blockchain_helium_packet_v1:new(
        lorawan,
        Payload,
        Timestamp,
        RSSI,
        Frequency,
        DataRate,
        SNR,
        {devaddr, 16#deadbeef}
    ),
    Region = 'US915',
    SCPacket = blockchain_state_channel_packet_v1:new(
        Packet,
        PubKeyBin,
        Region
    ),

    ok = packet_purchaser_sc_packet_handler:handle_packet(
        SCPacket,
        erlang:system_time(millisecond),
        self()
    ),

    #state{socket = Socket} = sys:get_state(WorkerPid),
    {ok, Port} = inet:port(Socket),

    Token = semtech_udp:token(),
    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = <<"SF11BW125">>,
    ok = fake_lns:pull_resp(FakeLNSPid, "127.0.0.1", Port, Token, #{
        data => DownlinkPayload,
        tmst => DownlinkTimestamp,
        freq => DownlinkFreq,
        datr => DownlinkDatr
    }),
    MAC = packet_purchaser_utils:pubkeybin_to_mac(PubKeyBin),
    Map = #{<<"txpk_ack">> => #{<<"error">> => <<"NONE">>}},

    ?assertEqual({ok, {Token, MAC, Map}}, fake_lns:rcv(FakeLNSPid, ?TX_ACK)),

    receive
        {send_response, SCResp} ->
            Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
            ?assertEqual(DownlinkPayload, blockchain_helium_packet_v1:payload(Downlink)),
            ?assertEqual(DownlinkTimestamp, blockchain_helium_packet_v1:timestamp(Downlink)),
            ?assertEqual(DownlinkFreq, blockchain_helium_packet_v1:frequency(Downlink)),
            ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
            ?assertEqual(
                erlang:binary_to_list(DownlinkDatr),
                blockchain_helium_packet_v1:datarate(Downlink)
            )
    after 3000 -> ct:fail("sc resp timeout")
    end,

    ok.

multi_hotspots(Config) ->
    FakeLNSPid = proplists:get_value(fake_lns, Config),
    {PubKeyBin1, WorkerPid1} = proplists:get_value(gateway, Config),

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey),
    {ok, WorkerPid2} = packet_purchaser_udp_sup:maybe_start_worker(PubKeyBin2, #{}),

    Payload1 = <<"payload1">>,
    Timestamp = erlang:system_time(millisecond),
    RSSI = -80.0,
    Frequency = 904.299,
    DataRate = "SF10BW125",
    SNR = 6.199,
    Packet1 = blockchain_helium_packet_v1:new(
        lorawan,
        Payload1,
        Timestamp,
        RSSI,
        Frequency,
        DataRate,
        SNR,
        {devaddr, 16#deadbeef}
    ),
    Region = 'US915',
    SCPacket1 = blockchain_state_channel_packet_v1:new(
        Packet1,
        PubKeyBin1,
        Region
    ),

    Payload2 = <<"payload2">>,
    Packet2 = blockchain_helium_packet_v1:new(
        lorawan,
        Payload2,
        Timestamp,
        RSSI,
        Frequency,
        DataRate,
        SNR,
        {devaddr, 16#deadbeef}
    ),
    SCPacket2 = blockchain_state_channel_packet_v1:new(
        Packet2,
        PubKeyBin2,
        Region
    ),

    ok = packet_purchaser_sc_packet_handler:handle_packet(
        SCPacket1,
        erlang:system_time(millisecond),
        self()
    ),

    ok = packet_purchaser_sc_packet_handler:handle_packet(
        SCPacket2,
        erlang:system_time(millisecond),
        self()
    ),

    {ok, Map0} = fake_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(Payload1),
                        <<"datr">> => DataRate,
                        <<"freq">> => Frequency,
                        <<"rfch">> => 0,
                        <<"lsnr">> => SNR,
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(RSSI),
                        <<"size">> => erlang:byte_size(Payload1),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(Timestamp / 1000)
                    }
                ]
            },
            Map0
        )
    ),

    {ok, Map1} = fake_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(Payload2),
                        <<"datr">> => DataRate,
                        <<"freq">> => Frequency,
                        <<"rfch">> => 0,
                        <<"lsnr">> => SNR,
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(RSSI),
                        <<"size">> => erlang:byte_size(Payload2),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(Timestamp / 1000)
                    }
                ]
            },
            Map1
        )
    ),

    %% Chekcing that the push data cache is empty as we should have gotten the push ack

    test_utils:wait_until(fun() ->
        State1 = sys:get_state(WorkerPid1),
        State1#state.push_data == #{} andalso self() == State1#state.sc_pid
    end),

    test_utils:wait_until(fun() ->
        State2 = sys:get_state(WorkerPid2),
        State2#state.push_data == #{} andalso self() == State2#state.sc_pid
    end),

    _ = gen_server:stop(WorkerPid2),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
