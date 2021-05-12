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
    pubkey_bin_test/1
]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [pubkey_bin_test].

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

pubkey_bin_test(_Config) ->

    DevEUI = <<"a5e802b270dd196e">>,

    DevNonce = crypto:strong_rand_bytes(2),
    AppKey = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,

    {ok, Socket} = gen_udp:open(0, [binary, {active, true}]),

    %% Chirpstack local testing gateway_id
    %% GatewayID = <<"c360747576ca24e2">>,
    %% PubKeyBin = pp_utils:hex_to_bin(GatewayID),

    %% jolly-bloody-condor
    %% PubKeyBin = <<0,53,88,135,139,114,108,118,52,64,241,19,167,238,15,14,189,5,47,221,252,101,253,217,142,71,113,165,71,115,145,172,60>>,

    %% amusing-felt-locust
    PubKeyBin = <<0,97,6,18,79,240,99,255,196,76,155,129,218,223,22,235,57,180,244,232,142,120,120,58,206,246,188,125,38,161,39,35,133>>,
    Mac = pp_utils:pubkeybin_to_mac(PubKeyBin),

    PullDataPacket = semtech_udp:pull_data(semtech_udp:token(), Mac),
    JoinPayload = semtech_udp:make_join_payload(AppKey, DevEUI, DevNonce),
    {ok, Token, JoinPacket} = semtech_udp:craft_push_data(JoinPayload, Mac),

    %% ?debugFmt("GatewayID: ~p", [GatewayID]),
    ?debugFmt("Token used: ~p", [Token]),

    ?debugFmt("Pull Data: ~p", [PullDataPacket]),
    ok = gen_udp:send(Socket, {0, 0, 0, 0}, 1701, PullDataPacket),

    timer:sleep(timer:seconds(2)),
    ?debugMsg("Sending join packet"),
    ok = gen_udp:send(Socket, {0, 0, 0, 0}, 1701, JoinPacket),

    ok = ignore_messages(),

    ok.

ignore_messages() ->
    receive
        Msg ->
            ?debugFmt("ignored message: ~p~n", [Msg]),
            ignore_messages()
    after 2000 -> ok
    end.

%% udp_test(_Config) ->
%%     DeviceDefaults = #{
%%         dev_eui => <<"a5e802b270dd196e">>,
%%         gateway => <<"c360747576ca24e2">>,
%%         dev_nonce => crypto:strong_rand_bytes(2),
%%         app_key => <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,
%%         context => <<1, 2, 3, 4>>
%%     },
%%     UDPArgs = #{
%%         address => {0, 0, 0, 0},
%%         port => 1701,
%%         pubkeybin => <<60, 6, 71, 87, 103, 172, 66, 46>>
%%     },

%%     {ok, Pid} = pp_udp_worker:start_link(UDPArgs),

%%     #{app_key := AppKey, dev_eui := DevEUI, dev_nonce := DevNonce} = DeviceDefaults,
%%     Join = semtech_udp:make_join_payload(AppKey, DevEUI, DevNonce),
%%     #{token := Token, packet := Packet} = semtech_udp:prep_with_payload(Join),
%%     pp_udp_worker:push_data(Pid, Token, Packet, self()),

%%     timer:sleep(timer:seconds(5)),

%%     ok.

%% mqtt_test(_Config) ->
%%     {ok, Pid} = pp_mqtt_device:start_link(),

%%     pp_mqtt_device:join(Pid),
%%     timer:sleep(timer:seconds(5)),

%%     pp_mqtt_device:uplink(Pid),
%%     timer:sleep(timer:seconds(5)),

%%     ok.
