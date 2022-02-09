-module(pp_ws_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    ws_init_test/1,
    ws_receive_packet_test/1,
    ws_console_update_config_test/1,
    ws_console_update_config_redirect_udp_worker_test/1,
    ws_active_inactive_test/1,
    ws_active_countdown_test/1,
    ws_stop_start_purchasing_test/1
]).

-include_lib("eunit/include/eunit.hrl").
-include("lorawan_vars.hrl").

%% NetIDs
-define(NET_ID, 16#000002).
%% DevAddrs
% pp_utils:hex_to_binary(<<"04ABCDEF">>)
-define(DEVADDR, <<4, 171, 205, 239>>).

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
        ws_init_test,
        ws_receive_packet_test,
        ws_console_update_config_test,
        ws_console_update_config_redirect_udp_worker_test,
        ws_active_inactive_test,
        ws_active_countdown_test,
        ws_stop_start_purchasing_test
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

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

ws_init_test(_Config) ->
    {ok, _} = test_utils:ws_init(),
    ok.

ws_receive_packet_test(_Config) ->
    {ok, _} = test_utils:ws_init(),

    ok = ws_send_bin(<<"packet_one">>),
    {ok, <<"packet_one">>} = test_utils:ws_test_rcv(),

    ok = ws_send_bin(<<"packet_two">>),
    {ok, <<"packet_two">>} = test_utils:ws_test_rcv(),

    ok = ws_send_bin(<<"packet_three">>),
    {ok, <<"packet_three">>} = test_utils:ws_test_rcv(),

    ok.

ws_active_inactive_test(_Config) ->
    {ok, _} = test_utils:ws_init(),

    ok = ws_send_bin(<<"should_receive">>),
    {ok, <<"should_receive">>} = test_utils:ws_test_rcv(),

    {ok, inactive} = pp_console_ws_worker:deactivate(),

    ok = ws_send_bin(<<"should_not_receive">>),
    ?assertException(
        exit,
        {test_case_failed, websocket_test_message_timeout},
        test_utils:ws_test_rcv()
    ),

    {ok, active} = pp_console_ws_worker:activate(),

    ok = ws_send_bin(<<"should_receive_again">>),
    {ok, <<"should_receive_again">>} = test_utils:ws_test_rcv(),

    ok.

ws_active_countdown_test(_Config) ->
    {ok, _} = test_utils:ws_init(),

    %% Turn on ws for 2 messages
    {ok, active} = pp_console_ws_worker:activate(2),

    ok = ws_send_bin(<<"should_receive_1">>),
    {ok, <<"should_receive_1">>} = test_utils:ws_test_rcv(),

    ok = ws_send_bin(<<"should_receive_2">>),
    {ok, <<"should_receive_2">>} = test_utils:ws_test_rcv(),

    ok = ws_send_bin(<<"should_not_receive">>),
    ?assertException(
        exit,
        {test_case_failed, websocket_test_message_timeout},
        test_utils:ws_test_rcv()
    ),

    ok.

ws_console_update_config_test(_Config) ->
    {ok, WSPid} = test_utils:ws_init(),
    OneMapped = [
        #{
            <<"name">> => "two",
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337
        }
    ],
    TwoMapped = [
        #{
            <<"name">> => "one",
            <<"net_id">> => 1,
            <<"address">> => <<>>,
            <<"port">> => 1337
        },
        #{
            <<"name">> => "two",
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337
        }
    ],
    TwoReMapped = [
        #{
            <<"name">> => "one",
            <<"net_id">> => 1,
            <<"address">> => <<>>,
            <<"port">> => 1337
        },
        #{
            <<"name">> => "two",
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1338
        }
    ],
    console_callback:update_config(WSPid, OneMapped),
    timer:sleep(500),
    ?assertEqual(
        {ok, pp_config:transform_config(OneMapped)},
        pp_config:get_config()
    ),

    console_callback:update_config(WSPid, TwoMapped),
    timer:sleep(500),
    ?assertEqual(
        {ok, pp_config:transform_config(TwoMapped)},
        pp_config:get_config()
    ),

    console_callback:update_config(WSPid, TwoReMapped),
    timer:sleep(500),
    ?assertEqual(
        {ok, pp_config:transform_config(TwoReMapped)},
        pp_config:get_config()
    ),

    ok.

ws_stop_start_purchasing_test(_Config) ->
    MakeOfferFun = fun() ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        test_utils:packet_offer(PubKeyBin, ?DEVADDR)
    end,

    {ok, WSPid} = test_utils:ws_init(),

    Config = [
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => 1337
        }
    ],

    _ = console_callback:update_config(WSPid, Config),
    timer:sleep(150),
    ok = test_utils:ignore_messages(),

    ?assertEqual(ok, pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())),
    ?assertEqual(ok, pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())),
    ?assertEqual(ok, pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())),

    ok = console_callback:stop_buying(WSPid, [?NET_ID]),
    timer:sleep(150),

    ?assertEqual(
        {error, buying_inactive, ?NET_ID},
        pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())
    ),
    ?assertEqual(
        {error, buying_inactive, ?NET_ID},
        pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())
    ),
    ?assertEqual(
        {error, buying_inactive, ?NET_ID},
        pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())
    ),

    ok = console_callback:start_buying(WSPid, [?NET_ID]),
    timer:sleep(150),

    ?assertEqual(ok, pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())),
    ?assertEqual(ok, pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())),
    ?assertEqual(ok, pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())),

    ok.

ws_console_update_config_redirect_udp_worker_test(_Config) ->
    %% Address1 = {127, 0, 0, 1},
    Port1 = 1337,
    Port2 = 1338,

    {ok, WSPid} = test_utils:ws_init(),

    Config1 = [
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => Port1
        }
    ],
    Config2 = [
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => Port2
        }
    ],

    %% Open sockets for receiving
    {ok, PrimarySocket} = gen_udp:open(Port1, [binary, {active, true}]),
    {ok, SecondarySocket} = gen_udp:open(Port2, [binary, {active, true}]),

    SendPacketFun = fun() ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, ?DEVADDR, 0, #{
            dont_encode => true
        }),
        _ = pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),
        ok
    end,

    %% Make sure nothing gets through
    ok = test_utils:ignore_messages(),
    ok = SendPacketFun(),
    ok =
        receive
            {udp, PrimarySocket, _, _, _} ->
                ct:fail({no_config, unexpected_message_on_primary_socket});
            {udp, SecondarySocket, _, _, _} ->
                ct:fail({no_config, unexpected_message_on_secondary_socket})
        after 1250 -> ok
        end,

    %% Send to first config
    console_callback:update_config(WSPid, Config1),
    timer:sleep(500),
    ok = test_utils:ignore_messages(),
    ok = SendPacketFun(),
    ok =
        receive
            {udp, PrimarySocket, _, _, _} ->
                ok;
            {udp, SecondarySocket, _, _, _} ->
                ct:fail({config_1, unexpected_message_on_secondary_socket})
        after 1250 -> ct:fail({config_1, unexpected_no_message})
        end,

    %% replace with second config and make sure new traffic is redirected
    console_callback:update_config(WSPid, Config2),
    timer:sleep(500),
    ok = test_utils:ignore_messages(),
    ok = SendPacketFun(),
    ok =
        receive
            {udp, PrimarySocket, _, _, _} ->
                ct:fail({config_2, unexpected_message_on_primary_socket});
            {udp, SecondarySocket, _, _, _} ->
                ok
        after 1250 -> ct:fail({config_2, unexpected_no_message})
        end,

    ok.

%% ------------------------------------------------------------------
%% Helper Functions
%% ------------------------------------------------------------------

ws_send_bin(Bin) ->
    pp_console_ws_worker:send(test_utils:ws_prepare_test_msg(Bin)).
