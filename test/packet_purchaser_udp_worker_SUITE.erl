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
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    Opts = packet_purchaser_lns:send_packet(PubKeyBin, #{}),
    {ok, Map0} = packet_purchaser_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts)),
                        <<"datr">> => maps:get(dr, Opts),
                        <<"freq">> => maps:get(freq, Opts),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(maps:get(timestamp, Opts) / 1000)
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
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, _WorkerPid} = proplists:get_value(gateway, Config),

    Opts0 = packet_purchaser_lns:send_packet(PubKeyBin, #{}),
    {ok, Map0} = packet_purchaser_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts0)),
                        <<"datr">> => maps:get(dr, Opts0),
                        <<"freq">> => maps:get(freq, Opts0),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts0),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts0)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts0)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(maps:get(timestamp, Opts0) / 1000)
                    }
                ]
            },
            Map0
        )
    ),

    ok = packet_purchaser_lns:delay_next_udp(FakeLNSPid, timer:seconds(3)),
    Opts1 = packet_purchaser_lns:send_packet(PubKeyBin, #{}),

    {ok, Map1} = packet_purchaser_lns:rcv(FakeLNSPid, ?PUSH_DATA, timer:seconds(4)),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts1)),
                        <<"datr">> => maps:get(dr, Opts1),
                        <<"freq">> => maps:get(freq, Opts1),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts1),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts1)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts1)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(maps:get(timestamp, Opts1) / 1000)
                    }
                ]
            },
            Map1
        )
    ),
    ok.

pull_data(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, _WorkerPid} = proplists:get_value(gateway, Config),

    {ok, {Token, MAC}} = packet_purchaser_lns:rcv(FakeLNSPid, ?PULL_DATA, timer:seconds(5)),
    ?assert(erlang:is_binary(Token)),
    ?assertEqual(packet_purchaser_utils:pubkeybin_to_mac(PubKeyBin), MAC),
    ok.

failed_pull_data(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {_PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    Ref = erlang:monitor(process, WorkerPid),
    ok = packet_purchaser_lns:delay_next_udp(FakeLNSPid, timer:seconds(5)),

    receive
        {'DOWN', Ref, process, WorkerPid, pull_data_timeout} ->
            true;
        Msg ->
            ct:fail("received unexpected message ~p", [Msg])
    after 5000 -> ct:fail("down timeout")
    end,

    ok.

pull_resp(Config) ->
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin, WorkerPid} = proplists:get_value(gateway, Config),

    _Opts = packet_purchaser_lns:send_packet(PubKeyBin, #{}),
    #state{socket = Socket} = sys:get_state(WorkerPid),
    {ok, Port} = inet:port(Socket),

    Token = semtech_udp:token(),
    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = <<"SF11BW125">>,
    ok = packet_purchaser_lns:pull_resp(FakeLNSPid, "127.0.0.1", Port, Token, #{
        data => DownlinkPayload,
        tmst => DownlinkTimestamp,
        freq => DownlinkFreq,
        datr => DownlinkDatr
    }),
    MAC = packet_purchaser_utils:pubkeybin_to_mac(PubKeyBin),
    Map = #{<<"txpk_ack">> => #{<<"error">> => <<"NONE">>}},

    ?assertEqual({ok, {Token, MAC, Map}}, packet_purchaser_lns:rcv(FakeLNSPid, ?TX_ACK)),

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
    FakeLNSPid = proplists:get_value(lns, Config),
    {PubKeyBin1, WorkerPid1} = proplists:get_value(gateway, Config),

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey),
    {ok, WorkerPid2} = packet_purchaser_udp_sup:maybe_start_worker(PubKeyBin2, #{}),

    Opts1 = packet_purchaser_lns:send_packet(PubKeyBin1, #{payload => <<"payload1">>}),
    Opts2 = packet_purchaser_lns:send_packet(PubKeyBin2, #{payload => <<"payload2">>}),

    {ok, Map0} = packet_purchaser_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts1)),
                        <<"datr">> => maps:get(dr, Opts1),
                        <<"freq">> => maps:get(freq, Opts1),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts1),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts1)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts1)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(maps:get(timestamp, Opts1) / 1000)
                    }
                ]
            },
            Map0
        )
    ),

    {ok, Map1} = packet_purchaser_lns:rcv(FakeLNSPid, ?PUSH_DATA),
    ?assert(
        test_utils:match_map(
            #{
                <<"rxpk">> => [
                    #{
                        <<"data">> => base64:encode(maps:get(payload, Opts2)),
                        <<"datr">> => maps:get(dr, Opts2),
                        <<"freq">> => maps:get(freq, Opts2),
                        <<"rfch">> => 0,
                        <<"lsnr">> => maps:get(snr, Opts2),
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => erlang:trunc(maps:get(rssi, Opts2)),
                        <<"size">> => erlang:byte_size(maps:get(payload, Opts2)),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => erlang:trunc(maps:get(timestamp, Opts2) / 1000)
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
