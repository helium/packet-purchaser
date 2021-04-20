-module(gateway_SUITE).

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
    mqtt_test/1,
    udp_test/1
]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [mqtt_test, udp_test].

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

udp_test(_Config) ->
    DeviceDefaults = #{
        dev_eui => <<"a5e802b270dd196e">>,
        gateway => <<"c360747576ca24e2">>,
        dev_nonce => crypto:strong_rand_bytes(2),
        app_key => <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,
        context => <<1, 2, 3, 4>>
    },
    UDPArgs = #{
        address => {0, 0, 0, 0},
        port => 1701,
        pubkeybin => <<60, 6, 71, 87, 103, 172, 66, 46>>
    },

    {ok, Pid} = pp_udp_worker:start_link(UDPArgs),

    #{app_key := AppKey, dev_eui := DevEUI, dev_nonce := DevNonce} = DeviceDefaults,
    Join = semtech_udp:make_join_payload(AppKey, DevEUI, DevNonce),
    #{token := Token, packet := Packet} = semtech_udp:prep_with_payload(Join),
    pp_udp_worker:push_data(Pid, Token, Packet, self()),

    timer:sleep(timer:seconds(5)),

    ok.

mqtt_test(_Config) ->
    {ok, Pid} = pp_mqtt_device:start_link(),

    pp_mqtt_device:join(Pid),
    timer:sleep(timer:seconds(5)),

    pp_mqtt_device:uplink(Pid),
    timer:sleep(timer:seconds(5)),

    ok.
