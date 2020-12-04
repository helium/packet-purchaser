-module(end_to_end_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("packet_purchaser.hrl").
-include("semtech_udp.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([full/1]).

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
    [full].

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

full(_Config) ->
    {ok, FakeLNSPid} = fake_lns:start_link(#{port => 1680, forward => self()}),

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
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),
    Region = 'US915',
    SCPacket = blockchain_state_channel_packet_v1:new(
        Packet,
        Hotspot,
        Region
    ),

    ok = packet_purchaser_sc_packet_handler:handle_packet(
        SCPacket,
        erlang:system_time(millisecond),
        self()
    ),

    receive
        {fake_lns, FakeLNSPid, ?PUSH_DATA, Map0} ->
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
            )
    after 500 -> ct:fail("fake_lns timeout")
    end,

    ok = fake_lns:delay_next_udp(FakeLNSPid),
    ok = packet_purchaser_sc_packet_handler:handle_packet(
        SCPacket,
        erlang:system_time(millisecond),
        self()
    ),

    receive
        {fake_lns, FakeLNSPid, ?PUSH_DATA, Map1} ->
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
            )
    after 3500 -> ct:fail("fake_lns timeout")
    end,

    gen_server:stop(FakeLNSPid),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------