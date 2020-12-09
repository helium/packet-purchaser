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
    pull_resp/1
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
    [push_data, delay_push_data, pull_data, failed_pull_data, pull_resp].

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
                        <<"stat">> => 0,
                        <<"lsnr">> => SNR,
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => RSSI,
                        <<"size">> => erlang:byte_size(Payload),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => Timestamp
                    }
                ]
            },
            Map0
        )
    ),

    %% Chekcing that the push data cache is empty as we should have gotten the push ack
    State = sys:get_state(WorkerPid),
    ?assertEqual(#{}, State#state.push_data),
    ?assertEqual(self(), State#state.sc_pid),

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
                        <<"stat">> => 0,
                        <<"lsnr">> => SNR,
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => RSSI,
                        <<"size">> => erlang:byte_size(Payload),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => Timestamp
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
                        <<"stat">> => 0,
                        <<"lsnr">> => SNR,
                        <<"modu">> => <<"LORA">>,
                        <<"rssi">> => RSSI,
                        <<"size">> => erlang:byte_size(Payload),
                        <<"time">> => fun erlang:is_binary/1,
                        <<"tmst">> => Timestamp
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

    #state{socket = Socket} = sys:get_state(WorkerPid),
    {ok, Port} = inet:port(Socket),

    Token = semtech_udp:token(),
    ok = fake_lns:pull_resp(FakeLNSPid, {127, 0, 0, 1}, Port, Token, #{}),
    MAC = packet_purchaser_utils:pubkeybin_to_mac(PubKeyBin),
    Map = #{<<"txpk_ack">> => #{<<"error">> => <<"NONE">>}},

    ?assertEqual({ok, {Token, MAC, Map}}, fake_lns:rcv(FakeLNSPid, ?TX_ACK)),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
