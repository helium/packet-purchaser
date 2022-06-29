-module(pp_metrics_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    net_id_offer_test/1
]).

-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").

%% NetIDs
-define(NET_ID_ACTILITY, 16#000002).
-define(NET_ID_COMCAST, 16#000022).
-define(NET_ID_ORANGE, 16#00000F).
-define(NET_ID_TEKTELIC, 16#000037).

%% DevAddrs

% pp_utils:hex_to_binary(<<"04ABCDEF">>)
-define(DEVADDR_ACTILITY, <<4, 171, 205, 239>>).
% pp_utils:hex_to_binary(<<"45000042">>)
-define(DEVADDR_COMCAST, <<69, 0, 0, 66>>).
% pp_utils:hex_to_binary(<<"0000041">>)
-define(DEVADDR_EXPERIMENTAL, <<0, 0, 0, 42>>).
%pp_utils:hex_to_binary(<<"1E123456">>)
-define(DEVADDR_ORANGE, <<30, 18, 52, 86>>).
% pp_utils:hex_to_binary(<<"6E123456">>)
-define(DEVADDR_TEKTELIC, <<110, 18, 52, 86>>).

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
        net_id_offer_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    application:set_env(packet_purchaser, metrics_unique_packet_lru_size, 2),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TESTS
%%--------------------------------------------------------------------
net_id_offer_test(_Config) ->
    %% UnusedNetID = 16#5F_FF_FF,
    DevaddrWithUnassignedNetID = <<(16#DF_F0_00_00):32/integer-unsigned>>,

    lists:foreach(fun send_offer/1, [
        ?DEVADDR_ACTILITY,
        ?DEVADDR_COMCAST,
        ?DEVADDR_EXPERIMENTAL,
        ?DEVADDR_ORANGE,
        ?DEVADDR_TEKTELIC,
        DevaddrWithUnassignedNetID
    ]),

    %% give some time for metrics to process
    timer:sleep(100),

    OfferCountForNetID = fun(NetID) ->
        prometheus_counter:value(packet_purchaser_offer_count, [NetID, packet, rejected])
    end,
    UniqueOfferCountForNetID = fun(NetID) ->
        prometheus_counter:value(packet_purchaser_unique_offer_count, [NetID, packet])
    end,

    %% 1 offer provided
    ?assertEqual(1, OfferCountForNetID(?NET_ID_ACTILITY)),
    ?assertEqual(1, OfferCountForNetID(?NET_ID_COMCAST)),
    ?assertEqual(1, OfferCountForNetID(?NET_ID_ORANGE)),
    ?assertEqual(1, OfferCountForNetID(?NET_ID_TEKTELIC)),
    ?assertEqual(1, OfferCountForNetID(unofficial_net_id)),

    %% For testing, the LRU is set to 2
    %% 1 unique offer
    ?assertEqual(1, UniqueOfferCountForNetID(?NET_ID_ACTILITY)),
    ?assertEqual(1, UniqueOfferCountForNetID(?NET_ID_COMCAST)),
    ?assertEqual(1, UniqueOfferCountForNetID(?NET_ID_ORANGE)),
    ?assertEqual(undefined, UniqueOfferCountForNetID(?NET_ID_TEKTELIC)),
    ?assertEqual(undefined, UniqueOfferCountForNetID(unofficial_net_id)),

    ok.

%% -------------------------------------------------------------------
%% Utils
%% -------------------------------------------------------------------

make_offer(DevAddr) ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    <<DevNum:32/integer-unsigned>> = DevAddr,
    Packet = blockchain_helium_packet_v1:new(
        lorawan,
        crypto:strong_rand_bytes(20),
        erlang:system_time(millisecond),
        -100.0,
        915.2,
        "SF8BW125",
        -12.0,
        {devaddr, DevNum}
    ),
    Offer0 = blockchain_state_channel_offer_v1:from_packet(Packet, PubKeyBin, 'US915'),
    Offer1 = blockchain_state_channel_offer_v1:sign(Offer0, SigFun),
    Offer1.

send_offer(DevAddr) ->
    _ = pp_sc_packet_handler:handle_offer(make_offer(DevAddr), self()).
