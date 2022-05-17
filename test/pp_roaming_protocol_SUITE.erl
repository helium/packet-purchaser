-module(pp_roaming_protocol_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    rx1_downlink_test/1,
    rx2_downlink_test/1
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
        rx1_downlink_test,
        rx2_downlink_test
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

rx1_downlink_test(_Config) ->
    PubKeyBin =
        <<0, 97, 6, 18, 79, 240, 99, 255, 196, 76, 155, 129, 218, 223, 22, 235, 57, 180, 244, 232,
            142, 120, 120, 58, 206, 246, 188, 125, 38, 161, 39, 35, 133>>,
    ok = pp_roaming_downlink:insert_handler(PubKeyBin, self()),

    Payload = <<"0x60c04e26e020000000a754ba934840c3bc120989b532ee4613e06e3dd5d95d9d1ceb9e20b1f2">>,
    RXDelay = 2,
    Frequency = 925.1,
    DataRate = 10,

    Input = #{
        <<"ProtocolVersion">> => <<"1.0">>,
        <<"SenderID">> => <<"0x600013">>,
        <<"ReceiverID">> => <<"0xc00053">>,
        <<"TransactionID">> => 17,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> => Payload,
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0x6081f9c306a777fd">>,

            <<"RXDelay1">> => RXDelay,
            <<"DLFreq1">> => Frequency,
            <<"DataRate1">> => DataRate,

            <<"FNSULToken">> =>
                <<"0x31316A6A4C6B73717734597A646E6B54666939735A73334537617241657767586A4771516735394662554D78673750396774533A55533931353A3831393139303636">>,
            <<"ClassMode">> => <<"A">>,
            <<"HiPriorityFlag">> => false
        }
    },

    {downlink, _Output, {Pid, SCResp}} = pp_roaming_protocol:handle_xmitdata_req(Input),
    ?assertEqual(Pid, self()),

    Downlink = blockchain_state_channel_response_v1:downlink(SCResp),

    ?assertEqual(
        pp_utils:hexstring_to_binary(Payload),
        blockchain_helium_packet_v1:payload(Downlink)
    ),
    ?assertEqual(Frequency, blockchain_helium_packet_v1:frequency(Downlink)),
    ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
    ?assertEqual(
        pp_lorawan:dr_to_datar('US915', DataRate),
        blockchain_helium_packet_v1:datarate(Downlink)
    ),

    ok.

rx2_downlink_test(_Config) ->
    PubKeyBin =
        <<0, 97, 6, 18, 79, 240, 99, 255, 196, 76, 155, 129, 218, 223, 22, 235, 57, 180, 244, 232,
            142, 120, 120, 58, 206, 246, 188, 125, 38, 161, 39, 35, 133>>,
    ok = pp_roaming_downlink:insert_handler(PubKeyBin, self()),

    Input = #{
        <<"ProtocolVersion">> => <<"1.0">>,
        <<"SenderID">> => <<"0x600013">>,
        <<"ReceiverID">> => <<"0xc00053">>,
        <<"TransactionID">> => 17,
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

            <<"FNSULToken">> =>
                <<"0x31316A6A4C6B73717734597A646E6B54666939735A73334537617241657767586A4771516735394662554D78673750396774533A55533931353A3831393139303636">>,
            <<"ClassMode">> => <<"A">>,
            <<"HiPriorityFlag">> => false
        }
    },

    {downlink, _Output, {Pid, SCResp}} = pp_roaming_protocol:handle_xmitdata_req(Input),
    ?assertEqual(Pid, self()),

    Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
    RX2 = blockchain_helium_packet_v1:rx2_window(Downlink),
    ?assertEqual(pp_lorawan:dr_to_datar('US915', 8), blockchain_helium_packet_v1:datarate(RX2)),
    ?assertEqual(923.3, blockchain_helium_packet_v1:frequency(RX2)),

    ok.
