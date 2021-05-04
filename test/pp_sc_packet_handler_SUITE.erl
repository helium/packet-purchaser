-module(pp_sc_packet_handler_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    accept_joins_test/1
]).

-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").

-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

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
    [accept_joins_test].

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

accept_joins_test(_Config) ->
    SendJoinOfferFun = fun() ->
        DevNonce = crypto:strong_rand_bytes(2),
        AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Offer = join_offer(PubKeyBin, AppKey, DevNonce),
        pp_sc_packet_handler:handle_offer(Offer, self())
    end,

    %% Make sure we can accept offers
    ok = application:set_env(packet_purchaser, accept_joins, true),
    ?assertMatch(ok, SendJoinOfferFun()),
    ?assertMatch(ok, SendJoinOfferFun()),

    %% Turn it off
    ok = application:set_env(packet_purchaser, accept_joins, false),
    ?assertMatch({error, not_accepting_joins}, SendJoinOfferFun()),
    ?assertMatch({error, not_accepting_joins}, SendJoinOfferFun()),

    %% Turn it back on
    ok = application:set_env(packet_purchaser, accept_joins, true),
    ?assertMatch(ok, SendJoinOfferFun()),
    ?assertMatch(ok, SendJoinOfferFun()),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

join_offer(PubKeyBin, AppKey, DevNonce) ->
    RoutingInfo = {eui, 1, 1},
    HeliumPacket = blockchain_helium_packet_v1:new(
        lorawan,
        join_payload(AppKey, DevNonce),
        1000,
        0,
        923.3,
        <<"SF8BW125">>,
        0.0,
        RoutingInfo
    ),

    blockchain_state_channel_offer_v1:from_packet(
        HeliumPacket,
        PubKeyBin,
        'US915'
    ).

join_payload(AppKey, DevNonce) ->
    MType = ?JOIN_REQ,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = reverse(?APPEUI),
    DevEUI = reverse(?DEVEUI),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:cmac(aes_cbc128, AppKey, Payload0, 4),
    <<Payload0/binary, MIC:4/binary>>.

%% ------------------------------------------------------------------
%% Lorawan Utils
%% ------------------------------------------------------------------

reverse(Bin) -> reverse(Bin, <<>>).

reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) -> reverse(Rest, <<H/binary, Acc/binary>>).
