-module(pp_roaming_protocol_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    rx1_timestamp_test/1,
    rx1_downlink_test/1,
    rx2_downlink_test/1,
    chirpstack_join_accept_test/1,
    class_c_downlink_test/1
]).

-include_lib("eunit/include/eunit.hrl").

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
        rx1_timestamp_test,
        rx1_downlink_test,
        rx2_downlink_test,
        chirpstack_join_accept_test,
        class_c_downlink_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    ok = pp_roaming_downlink:init_ets(),
    Config.
%% test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    ok.
%% test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------


class_c_downlink_test(_Config) ->
    TransactionID = 2176,
    pp_roaming_downlink:insert_handler(TransactionID, self()),

    Token = pp_roaming_protocol:make_uplink_token(
        TransactionID,
        'US915',
        erlang:system_time(millisecond),
        <<"www.example.com">>,
        sync
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"ReceiverID">> => <<"0xc00053">>,
        <<"SenderID">> => <<"0x600013">>,
        <<"DLMetaData">> => #{
            <<"ClassMode">> => <<"C">>,
            <<"DLFreq2">> => 869.525,
            <<"DataRate2">> => 8,
            <<"DevEUI">> => <<"0x6081f9c306a777fd">>,
            <<"FNSULToken">> => Token,
            <<"HiPriorityFlag">> => false,
            <<"RXDelay1">> => 0
        },
        <<"PHYPayload">> => <<"0x60c04e26e000010001ae6cb4ddf7bc1997">>,
        <<"TransactionID">> => rand:uniform(16#FFFF_FFFF)
    },

    Self = self(),
    ?assertMatch({downlink, #{}, {Self, _}, _Dest}, pp_roaming_protocol:handle_message(Input)),

    ok.

chirpstack_join_accept_test(_Config) ->
    TransactionID = 473719436,
    pp_roaming_downlink:insert_handler(TransactionID, self()),

    Token = pp_roaming_protocol:make_uplink_token(
        TransactionID,
        'US915',
        erlang:system_time(millisecond),
        <<"www.example.com">>,
        sync
    ),

    A = #{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"MessageType">> => <<"PRStartAns">>,
        <<"ReceiverID">> => <<"C00053">>,
        <<"SenderID">> => <<"600013">>,
        <<"DLMetaData">> => #{
            <<"ClassMode">> => <<"A">>,
            <<"DLFreq1">> => 925.1,
            <<"DLFreq2">> => 923.3,
            <<"DataRate1">> => 10,
            <<"DataRate2">> => 8,
            <<"DevEUI">> => <<"6081f9c306a777fd">>,
            <<"FNSULToken">> => Token,
            <<"GWInfo">> => [#{}],
            <<"RXDelay1">> => 5
        },
        <<"DevAddr">> => <<"e0279ae8">>,
        <<"DevEUI">> => <<"6081f9c306a777fd">>,
        <<"FCntUp">> => 0,
        <<"FNwkSIntKey">> => #{
            <<"AESKey">> => <<"79dfbf88d0214e6f4b33360e987e9d50">>,
            <<"KEKLabel">> => <<>>
        },
        <<"Lifetime">> => 0,
        <<"PHYPayload">> =>
            <<"203851b55db2b1669f2c83a52b4b586d8ecca19880f22f6adda429dd719021160c">>,
        <<"Result">> => #{<<"Description">> => <<>>, <<"ResultCode">> => <<"Success">>},
        <<"TransactionID">> => TransactionID,
        <<"VSExtension">> => #{}
    },
    Self = self(),
    ?assertMatch({join_accept, {Self, _}}, pp_roaming_protocol:handle_message(A)),

    ok.

rx1_timestamp_test(_Config) ->
    TransactionID = 17,
    ok = pp_roaming_downlink:insert_handler(TransactionID, self()),

    PacketTime = 0,
    Token = pp_roaming_protocol:make_uplink_token(
        TransactionID,
        'US915',
        PacketTime,
        <<"www.example.com">>,
        sync
    ),

    MakeInput = fun(RXDelay) ->
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderID">> => <<"0x600013">>,
            <<"ReceiverID">> => <<"0xc00053">>,
            <<"TransactionID">> => rand:uniform(16#FFFF_FFFF),
            <<"MessageType">> => <<"XmitDataReq">>,
            <<"PHYPayload">> =>
                <<"0x60c04e26e020000000a754ba934840c3bc120989b532ee4613e06e3dd5d95d9d1ceb9e20b1f2">>,
            <<"DLMetaData">> => #{
                <<"DevEUI">> => <<"0x6081f9c306a777fd">>,

                <<"RXDelay1">> => RXDelay,
                <<"DLFreq1">> => 925.1,
                <<"DataRate1">> => 10,

                <<"FNSULToken">> => Token,

                <<"ClassMode">> => <<"A">>,
                <<"HiPriorityFlag">> => false
            }
        }
    end,

    lists:foreach(
        fun({RXDelay, ExpectedTimestamp}) ->
            Input = MakeInput(RXDelay),
            {downlink, _, {_, SCResp}, _} = pp_roaming_protocol:handle_xmitdata_req(Input),
            Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
            Timestamp = blockchain_helium_packet_v1:timestamp(Downlink),
            ?assertEqual(ExpectedTimestamp, Timestamp)
        end,
        [
            {0, 1_000_000},
            {1, 1_000_000},
            {2, 2_000_000},
            {3, 3_000_000}
        ]
    ),

    ok.

rx1_downlink_test(_Config) ->
    TransactionID = 17,
    ok = pp_roaming_downlink:insert_handler(TransactionID, self()),

    Payload = <<"0x60c04e26e020000000a754ba934840c3bc120989b532ee4613e06e3dd5d95d9d1ceb9e20b1f2">>,
    RXDelay = 2,
    Frequency = 925.1,
    DataRate = 10,

    Token = pp_roaming_protocol:make_uplink_token(
        TransactionID,
        'US915',
        erlang:system_time(millisecond),
        <<"www.example.com">>,
        sync
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"SenderID">> => <<"0x600013">>,
        <<"ReceiverID">> => <<"0xc00053">>,
        <<"TransactionID">> => rand:uniform(16#FFFF_FFFF),
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> => Payload,
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0x6081f9c306a777fd">>,

            <<"RXDelay1">> => RXDelay,
            <<"DLFreq1">> => Frequency,
            <<"DataRate1">> => DataRate,

            <<"FNSULToken">> => Token,
            <<"ClassMode">> => <<"A">>,
            <<"HiPriorityFlag">> => false
        }
    },

    {downlink, _Output, {Pid, SCResp}, _Dest} = pp_roaming_protocol:handle_xmitdata_req(Input),
    ?assertEqual(Pid, self()),

    Downlink = blockchain_state_channel_response_v1:downlink(SCResp),

    ?assertEqual(
        pp_utils:hexstring_to_binary(Payload),
        blockchain_helium_packet_v1:payload(Downlink)
    ),
    ?assertEqual(Frequency, blockchain_helium_packet_v1:frequency(Downlink)),
    ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
    ?assertEqual(
        pp_lorawan:index_to_datarate('US915', DataRate),
        blockchain_helium_packet_v1:datarate(Downlink)
    ),

    ok.

rx2_downlink_test(_Config) ->
    TransactionID = 17,
    ok = pp_roaming_downlink:insert_handler(TransactionID, self()),

    Token = pp_roaming_protocol:make_uplink_token(
        TransactionID,
        'US915',
        erlang:system_time(millisecond),
        <<"www.example.com">>,
        sync
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"SenderID">> => <<"0x600013">>,
        <<"ReceiverID">> => <<"0xc00053">>,
        <<"TransactionID">> => rand:uniform(16#FFFF_FFFF),
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> =>
            <<"0x60c04e26e020000000a754ba934840c3bc120989b532ee4613e06e3dd5d95d9d1ceb9e20b1f2">>,
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0x6081f9c306a777fd">>,

            <<"RXDelay1">> => 1,
            <<"DLFreq1">> => 925.1,
            <<"DataRate1">> => 10,

            <<"DLFreq2">> => 923.3,
            <<"DataRate2">> => 8,

            <<"FNSULToken">> => Token,
            <<"ClassMode">> => <<"A">>,
            <<"HiPriorityFlag">> => false
        }
    },

    {downlink, _Output, {Pid, SCResp}, _Dest} = pp_roaming_protocol:handle_xmitdata_req(Input),
    ?assertEqual(Pid, self()),

    Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
    RX2 = blockchain_helium_packet_v1:rx2_window(Downlink),
    ?assertEqual(
        pp_lorawan:index_to_datarate('US915', 8),
        blockchain_helium_packet_v1:datarate(RX2)
    ),
    ?assertEqual(923.3, blockchain_helium_packet_v1:frequency(RX2)),

    ok.
