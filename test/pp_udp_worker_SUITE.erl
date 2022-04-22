-module(pp_udp_worker_SUITE).

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
    missing_push_data_ack/1,
    pull_data_active/1,
    pull_data_inactive/1,
    failed_pull_data/1,
    pull_resp/1,
    multi_hotspots/1,
    tee_test/1,
    shutdown_test/1
]).

-record(state, {
    location :: {pos_integer(), float(), float()} | undefined,
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    net_id :: non_neg_integer(),
    socket :: pp_udp_socket:socket(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    sc_pid :: undefined | pid(),
    pull_data :: {reference(), binary()} | undefined,
    pull_data_timer :: non_neg_integer(),
    shutdown_timer :: {Timeout :: non_neg_integer(), Timer :: reference()}
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
    [
        push_data,
        delay_push_data,
        missing_push_data_ack,
        pull_data_active,
        pull_data_inactive,
        failed_pull_data,
        pull_resp,
        multi_hotspots,
        tee_test,
        shutdown_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config0) ->
    GatewayConfig =
        case TestCase of
            pull_data_active -> #{disable_pull_data => false};
            pull_data_inactive -> #{disable_pull_data => true};
            _ -> #{}
        end,
    Config1 = [{gateway_config, GatewayConfig} | Config0],
    Config2 = test_utils:init_per_testcase(TestCase, Config1),

    {ok, NetID} = lora_subnet:parse_netid(16#deadbeef),
    ok = pp_config:load_config([
        #{
            <<"name">> => <<"udp_worker_test">>,
            <<"net_id">> => NetID,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => 1337,
            <<"disable_pull_data">> => true
        }
    ]),
    Config2.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

push_data(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    Opts = pp_lns:send_packet(PubKeyBin, #{}),
    {ok, Map0} = pp_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts)),
                        <<"datr">> => erlang:list_to_binary(maps:get(dr, Opts)),
                        <<"freq">> => maps:get(freq, Opts),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => maps:get(timestamp, Opts) band 16#FFFFFFFF,
                        <<"codr">> => <<"4/5">>,
                        <<"stat">> => 1,
                        <<"chan">> => 0
                    }
                ],
                <<"stat">> => #{
                    <<"regi">> => <<"US915">>,
                    <<"inde">> => <<"undefined">>,
                    <<"lati">> => <<"undefined">>,
                    <<"long">> => <<"undefined">>,
                    <<"pubk">> => libp2p_crypto:bin_to_b58(PubKeyBin)
                }
            },
            Map0
        )
    ),

    %% Chekcing that the push data cache is empty as we should have gotten the push ack
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(WorkerPid),
        State#state.push_data == #{} andalso self() == State#state.sc_pid
    end),

    ok.

shutdown_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    DevAddr = <<(16#deadbeef):32/integer-unsigned>>,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr),
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(2#010, PubKeyBin, DevAddr, 0, Routing, #{
        dont_encode => true
    }),

    %% Shutdown if worker is unused
    {ok, WorkerPid1} = pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, #{shutdown_timer => 100}),
    ?assert(erlang:is_process_alive(WorkerPid1)),
    timer:sleep(120),
    ?assertNot(erlang:is_process_alive(WorkerPid1)),

    %% Shutdown is delayed by pushing data
    {ok, WorkerPid2} = pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, #{shutdown_timer => 100}),
    ?assert(erlang:is_process_alive(WorkerPid2)),
    timer:sleep(50),
    ok = pp_udp_worker:push_data(WorkerPid2, Packet, 123456789, self()),
    timer:sleep(50),
    ?assert(erlang:is_process_alive(WorkerPid2)),
    timer:sleep(100),
    ?assertNot(erlang:is_process_alive(WorkerPid2)),

    ok.

delay_push_data(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    Opts0 = pp_lns:send_packet(PubKeyBin, #{}),
    {ok, Map0} = pp_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts0)),
                        <<"datr">> => erlang:list_to_binary(maps:get(dr, Opts0)),
                        <<"freq">> => maps:get(freq, Opts0),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts0),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts0)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts0)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => maps:get(timestamp, Opts0) band 16#FFFFFFFF,
                        <<"codr">> => <<"4/5">>,
                        <<"stat">> => 1,
                        <<"chan">> => 0
                    }
                ],
                <<"stat">> => fun erlang:is_map/1
            },
            Map0
        )
    ),

    ok = pp_lns:delay_next_udp(FakeLNSPid, timer:seconds(3)),
    Opts1 = pp_lns:send_packet(PubKeyBin, #{}),

    {ok, Map1} = pp_lns:rcv(FakeLNSPid, ?PUSH_DATA, timer:seconds(4)),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts1)),
                        <<"datr">> => erlang:list_to_binary(maps:get(dr, Opts1)),
                        <<"freq">> => maps:get(freq, Opts1),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts1),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts1)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts1)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => maps:get(timestamp, Opts1) band 16#FFFFFFFF,
                        <<"codr">> => <<"4/5">>,
                        <<"stat">> => 1,
                        <<"chan">> => 0
                    }
                ],
                <<"stat">> => fun erlang:is_map/1
            },
            Map1
        )
    ),

    %% Checking that the push data cache is empty as we should have gotten the push ack
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(WorkerPid),
        State#state.push_data == #{} andalso self() == State#state.sc_pid
    end),

    ok.

missing_push_data_ack(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    Opts0 = pp_lns:send_packet(PubKeyBin, #{}),
    {ok, Map0} = pp_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts0)),
                        <<"datr">> => erlang:list_to_binary(maps:get(dr, Opts0)),
                        <<"freq">> => maps:get(freq, Opts0),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts0),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts0)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts0)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => maps:get(timestamp, Opts0) band 4294967295,
                        <<"codr">> => <<"4/5">>,
                        <<"stat">> => 1,
                        <<"chan">> => 0
                    }
                ],
                <<"stat">> => fun erlang:is_map/1
            },
            Map0
        )
    ),

    ok = pp_lns:delay_next_udp_forever(FakeLNSPid),
    _Opts1 = pp_lns:send_packet(PubKeyBin, #{}),

    ok = pp_lns:not_rcv(FakeLNSPid, ?PUSH_DATA, timer:seconds(3)),

    %% Checking that the push data cache is full as we should have _not_ gotten the push ack
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(WorkerPid),
        State#state.push_data == #{} andalso self() == State#state.sc_pid
    end),

    ok.

pull_data_active(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, _WorkerPid} = proplists:get_value(gateway, Config),

    {ok, {Token, MAC}} = pp_lns:rcv(FakeLNSPid, ?PULL_DATA, timer:seconds(5)),
    ?assert(erlang:is_binary(Token)),
    ?assertEqual(pp_utils:pubkeybin_to_mac(PubKeyBin), MAC),
    ok.

pull_data_inactive(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {_PubKeyBin, _WorkerPid} = proplists:get_value(gateway, Config),

    ?assertException(
        exit,
        {test_case_failed, "pp_lns rcv timeout"},
        pp_lns:rcv(FakeLNSPid, ?PULL_DATA, timer:seconds(5))
    ),

    ok.

failed_pull_data(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {_PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    %% Speed up the rate we check for pull_acks
    sys:replace_state(WorkerPid, fun(State) -> State#state{pull_data_timer = 20} end),

    ok = pp_lns:delay_next_udp(FakeLNSPid, timer:seconds(5)),
    timer:sleep(timer:seconds(1)),

    %% Gateways should ignore missed pull_ack messages
    ?assert(erlang:is_process_alive(WorkerPid)),

    ok.

pull_resp(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    _Opts = pp_lns:send_packet(PubKeyBin, #{}),
    #state{socket = {socket, Socket, _, _}} = sys:get_state(WorkerPid),
    {ok, Port} = inet:port(Socket),

    Token = semtech_udp:token(),
    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = <<"SF11BW125">>,
    ok = pp_lns:pull_resp(FakeLNSPid, "127.0.0.1", Port, Token, #{
        data => DownlinkPayload,
        tmst => DownlinkTimestamp,
        freq => DownlinkFreq,
        datr => DownlinkDatr,
        powe => 27
    }),
    MAC = pp_utils:pubkeybin_to_mac(PubKeyBin),
    Map = #{<<"txpk_ack">> => #{<<"error">> => <<"NONE">>}},

    ?assertEqual({ok, {Token, MAC, Map}}, pp_lns:rcv(FakeLNSPid, ?TX_ACK)),

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

tee_test(_Config) ->
    Address = {127, 0, 0, 1},
    Port1 = 1337,
    Port2 = 1338,

    %% Start a new worker with a Tee stream
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% NOTE: NetID doesn't matter here because we're pushing data directly
    %% through the udp worker, not going through the packet_handler.
    {ok, Pid} = pp_udp_sup:maybe_start_worker({PubKeyBin, 0}, #{
        address => Address,
        port => Port1,
        tee => {Address, Port2}
    }),

    %% Open sockets for receiving
    {ok, PrimarySocket} = gen_udp:open(Port1, [binary, {active, true}]),
    {ok, TeeSocket} = gen_udp:open(Port2, [binary, {active, true}]),

    %% Push data through worker
    Packet = blockchain_helium_packet_v1:new(),
    SCPacket = blockchain_state_channel_packet_v1:new(Packet, PubKeyBin, 'US915'),
    PacketTime = 0,
    ok = pp_udp_worker:push_data(Pid, SCPacket, PacketTime, self()),

    %% Receive on primary socket
    Receive1 =
        receive
            {udp, PrimarySocket, A1, P1, D1} -> {A1, P1, D1}
        after 1000 -> ct:fail("no primary message")
        end,

    %% Receive on tee socket
    Receive2 =
        receive
            {udp, TeeSocket, A2, P2, D2} -> {A2, P2, D2}
        after 1000 -> ct:fail("no tee message")
        end,

    %% Make sure both sockets received the same data
    ?assertEqual(Receive1, Receive2),

    %% shut it all down
    ok = gen_udp:close(PrimarySocket),
    ok = gen_udp:close(TeeSocket),
    ok = gen_server:stop(Pid),

    ok.

multi_hotspots(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin1, WorkerPid1} = proplists:get_value(gateway, Config),

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey),
    %% NetID to ensure sending packets from pp_lns get routed to this worker
    {ok, NetID} = lora_subnet:parse_netid(16#deadbeef),
    {ok, WorkerPid2} = pp_udp_sup:maybe_start_worker({PubKeyBin2, NetID}, #{}),

    Opts1 = pp_lns:send_packet(PubKeyBin1, #{payload => <<"payload1">>}),
    Opts2 = pp_lns:send_packet(PubKeyBin2, #{payload => <<"payload2">>}),

    {ok, Map0} = pp_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts1)),
                        <<"datr">> => erlang:list_to_binary(maps:get(dr, Opts1)),
                        <<"freq">> => maps:get(freq, Opts1),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts1),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts1)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts1)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => maps:get(timestamp, Opts1) band 16#FFFFFFFF,
                        <<"codr">> => <<"4/5">>,
                        <<"stat">> => 1,
                        <<"chan">> => 0
                    }
                ],
                <<"stat">> => fun erlang:is_map/1
            },
            Map0
        )
    ),

    {ok, Map1} = pp_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts2)),
                        <<"datr">> => erlang:list_to_binary(maps:get(dr, Opts2)),
                        <<"freq">> => maps:get(freq, Opts2),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts2),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts2)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts2)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => maps:get(timestamp, Opts2) band 16#FFFFFFFF,
                        <<"codr">> => <<"4/5">>,
                        <<"stat">> => 1,
                        <<"chan">> => 0
                    }
                ],
                <<"stat">> => fun erlang:is_map/1
            },
            Map1
        )
    ),

    %% Chekcing that the push data cache is empty as we should have gotten the push ack

    ok = test_utils:wait_until(fun() ->
        State1 = sys:get_state(WorkerPid1),
        State1#state.push_data == #{} andalso self() == State1#state.sc_pid
    end),

    ok = test_utils:wait_until(fun() ->
        State2 = sys:get_state(WorkerPid2),
        State2#state.push_data == #{} andalso self() == State2#state.sc_pid
    end),

    _ = gen_server:stop(WorkerPid2),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
