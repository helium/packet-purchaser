-module(end_to_end_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("packet_purchaser.hrl").
-include("lorawan_gwmp.hrl").

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
init_per_testcase(_TestCase, Config) ->
    {ok, _} = application:ensure_all_started(?APP),
    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    application:stop(?APP),
    ok.

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
    Hotspot = <<"hotspot">>,
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
        {fake_lns, FakeLNSPid, ?PUSH_DATA, Map} ->
            ?assert(
                test_utils:match_map(
                    #{
                        <<"rxpk">> => [
                            #{
                                <<"data">> => base64:encode(Payload),
                                <<"datr">> => DataRate,
                                <<"freq">> => Frequency,
                                <<"lsnr">> => SNR,
                                <<"modu">> => <<"LORA">>,
                                <<"rssi">> => RSSI,
                                <<"size">> => erlang:byte_size(Payload),
                                <<"time">> => fun erlang:is_binary/1,
                                <<"tmst">> => Timestamp
                            }
                        ]
                    },
                    Map
                )
            )
    after 500 -> ct:fail("fake_lns timeout")
    end,

    gen_server:stop(FakeLNSPid),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
