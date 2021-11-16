-module(pp_metrics_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    net_ids_counter_test/1,
    net_ids_offer_counter_test/1,
    location_counter_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").

%% NetIDs
-define(NET_ID_ACTILITY, 16#000002).
-define(NET_ID_COMCAST, 16#000022).
-define(NET_ID_EXPERIMENTAL, 16#000000).
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
        %% net_ids_counter_test,
        %% net_ids_offer_counter_test,
        %% location_counter_test
    ].

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

location_counter_test(_Config) ->
    SendPacketFun = fun(DevAddr, PubKeyBins) ->
        lists:foreach(
            fun(PubKeyBin) ->
                Packet = test_utils:frame_packet(
                    ?UNCONFIRMED_UP,
                    PubKeyBin,
                    DevAddr,
                    0,
                    #{dont_encode => true}
                ),
                pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self())
            end,
            PubKeyBins
        )
    end,

    ActilityDevAddr = pp_utils:hex_to_binary(<<"04ABCDEF">>),
    OrangeDevAddr = pp_utils:hex_to_binary(<<"1E123456">>),
    ComcastDevAddr = pp_utils:hex_to_binary(<<"45000042">>),

    WinterHaven = libp2p_crypto:b58_to_bin("1129zHtCXModu3mzP98TMCs63WZnm2xGT3WHQQbmizgEmqWQw9Vd"),
    Bloomington = libp2p_crypto:b58_to_bin("112goQHPf921bTU2c46zSvETfLqcdT1RQwvX9NDucHHBVrEMJuBp"),
    Burnaby = libp2p_crypto:b58_to_bin("112s3a4PkmZZt3F9qD1nhrF643D8uaY4dwmznyRKMpXkcsAWrnkF"),

    SendPacketFun(
        ActilityDevAddr,
        [WinterHaven, Bloomington, Burnaby]
    ),
    SendPacketFun(
        OrangeDevAddr,
        [WinterHaven, Bloomington]
    ),
    SendPacketFun(
        ComcastDevAddr,
        [WinterHaven]
    ),

    ok = wait_until_messages_consumed(whereis(pp_metrics)),

    Expected = #{WinterHaven => 3, Bloomington => 2, Burnaby => 1},
    %%     {<<"United States">>, <<"Florida">>, <<"Winter Haven">>} => 3,
    %%     {<<"United States">>, <<"California">>, <<"Bloomington">>} => 2,
    %%     {<<"Canada">>, <<"British Columbia">>, <<"Burnaby">>} => 1
    %% },
    Actual = pp_metrics:get_location_packet_counts(),
    ?assertEqual(Expected, Actual),

    ok.

net_ids_offer_counter_test(_Config) ->
    MakeOfferFun = fun(DevAddr) ->
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
        Offer1
    end,

    SendOfferFun = fun(DevAddr) ->
        _ = pp_sc_packet_handler:handle_offer(MakeOfferFun(DevAddr), self())
    end,

    application:set_env(packet_purchaser, net_ids, #{
        ?NET_ID_ACTILITY => #{address => "1.1.1.1", port => 1111},
        ?NET_ID_ORANGE => #{address => "2.2.2.2", port => 2222},
        ?NET_ID_COMCAST => #{address => "3.3.3.3", port => 3333}
    }),

    true = ets:delete_all_objects(pp_metrics_ets),

    lists:foreach(
        fun(_) -> SendOfferFun(?DEVADDR_ACTILITY) end,
        lists:seq(1, 4)
    ),

    lists:foreach(
        fun(_) -> SendOfferFun(?DEVADDR_ORANGE) end,
        lists:seq(1, 3)
    ),

    lists:foreach(
        fun(_) -> SendOfferFun(?DEVADDR_COMCAST) end,
        lists:seq(1, 2)
    ),

    lists:foreach(
        fun(_) -> SendOfferFun(?DEVADDR_TEKTELIC) end,
        lists:seq(1, 10)
    ),
    ok = wait_until_messages_consumed(whereis(pp_metrics)),

    %% Offers
    ExpectedPackets = #{?NET_ID_ACTILITY => 4, ?NET_ID_ORANGE => 3, ?NET_ID_COMCAST => 2},
    ExpectedOffers = maps:merge(ExpectedPackets, #{?NET_ID_TEKTELIC => 10}),
    ActualOffers = pp_metrics:get_netid_offer_counts(),
    ?assertEqual(ExpectedOffers, ActualOffers),

    ok.

net_ids_counter_test(_Config) ->
    SendPacketFun = fun(DevAddr, NetID) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{
            dont_encode => true
        }),

        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        case pp_udp_sup:lookup_worker({PubKeyBin, NetID}) of
            {ok, Pid} ->
                {
                    state,
                    _Chain,
                    _Loc,
                    PubKeyBin,
                    _Socket,
                    Address,
                    Port,
                    _PushData,
                    _ScPid,
                    _PullData,
                    _PullDataTimer
                } = sys:get_state(Pid),
                {Address, Port};
            {error, not_found} ->
                noproc
        end
    end,

    application:set_env(packet_purchaser, net_ids, #{
        ?NET_ID_ACTILITY => #{address => "1.1.1.1", port => 1111},
        ?NET_ID_ORANGE => #{address => "2.2.2.2", port => 2222},
        ?NET_ID_COMCAST => #{address => "3.3.3.3", port => 3333}
    }),

    true = ets:delete_all_objects(pp_metrics_ets),

    lists:foreach(
        fun(_) ->
            ?assertMatch({"1.1.1.1", 1111}, SendPacketFun(?DEVADDR_ACTILITY, ?NET_ID_ACTILITY))
        end,
        lists:seq(1, 4)
    ),

    lists:foreach(
        fun(_) ->
            ?assertMatch({"2.2.2.2", 2222}, SendPacketFun(?DEVADDR_ORANGE, ?NET_ID_ORANGE))
        end,
        lists:seq(1, 3)
    ),

    lists:foreach(
        fun(_) ->
            ?assertMatch({"3.3.3.3", 3333}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST))
        end,
        lists:seq(1, 2)
    ),

    lists:foreach(
        fun(_) -> ?assertMatch(noproc, SendPacketFun(?DEVADDR_TEKTELIC, ?NET_ID_TEKTELIC)) end,
        lists:seq(1, 10)
    ),

    ok = wait_until_messages_consumed(whereis(pp_metrics)),

    %% Packets
    ExpectedPackets = #{?NET_ID_ACTILITY => 4, ?NET_ID_ORANGE => 3, ?NET_ID_COMCAST => 2},
    ActualPackets = pp_metrics:get_netid_packet_counts(),
    ?assertEqual(ExpectedPackets, ActualPackets),

    ok.

%% -------------------------------------------------------------------
%% Utils
%% -------------------------------------------------------------------

wait_until_messages_consumed(Pid) ->
    ok = test_utils:wait_until(
        fun() ->
            case erlang:process_info(Pid, message_queue_len) of
                {message_queue_len, 0} -> true;
                {message_queue_len, Count} -> {messages_left, Count}
            end
        end,
        _Retries = 100,
        _Delay = 200
    ),

    timer:sleep(200),
    ok.
