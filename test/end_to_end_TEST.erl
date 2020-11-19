-module(end_to_end_TEST).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("packet_purchaser.hrl").

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
    {ok, Socket} = gen_udp:open(1680, [binary, {active, true}]),

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

    LoRaPacket =
        receive
            {udp, Socket, _IP, _Port, P} -> P
        after 500 -> ct:fail("socket timeout")
        end,

    <<Protocol:8/integer-unsigned, _Token:2/binary, PushData:8/integer-unsigned, MAC:64/integer,
        BinJSX/binary>> = LoRaPacket,

    ?assertEqual(2, Protocol),
    ?assertEqual(0, PushData),
    ?assertEqual(0, MAC),
    Map = jsx:decode(BinJSX),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Map]),
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
    ),

    gen_udp:close(Socket),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
