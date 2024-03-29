-module(pp_ws_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    ws_init_test/1,
    ws_close_test/1,
    ws_receive_packet_test/1,
    ws_console_update_config_test/1,
    ws_console_update_config_redirect_udp_worker_test/1,
    ws_stop_start_purchasing_test/1,
    ws_request_address_test/1
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
        ws_close_test,
        ws_receive_packet_test,
        ws_console_update_config_test,
        ws_console_update_config_redirect_udp_worker_test,
        ws_stop_start_purchasing_test,
        ws_request_address_test
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

ws_close_test(_Config) ->
    %% The websocket conection should already be started by now We
    %% want to kill that connection and make sure a whole new
    %% ws_client is started. That means we've fetched a new token from
    %% Console.
    meck:new(pp_console_ws_client, [passthrough]),

    {ok, WSPid} = test_utils:ws_init(),

    ?assertNot(meck:called(pp_console_ws_client, start_link, '_')),
    exit(WSPid, kill),

    {ok, _WSPid} = test_utils:ws_init(),
    ?assert(meck:called(pp_console_ws_client, start_link, '_')),

    ?assert(meck:validate(pp_console_ws_client)),
    meck:unload(),

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

ws_request_address_test(_Config) ->
    {ok, WSPid} = test_utils:ws_init(),

    PubKeyBin = blockchain_swarm:pubkey_bin(),
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),

    console_callback:request_address(WSPid),
    ?assertMatch(
        {ok, #{
            event := <<"packet_purchaser:address">>,
            payload := #{<<"address">> := B58}
        }},
        test_utils:ws_roaming_rcv(pp_request_address)
    ),

    ok.

ws_console_update_config_test(_Config) ->
    %% NOTE: true is the default in test.config. This is for communication purposes.
    ok = application:set_env(packet_purchaser, update_from_ws_config, true),
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

    %% Now we turn off taking config updates from ws
    ok = application:set_env(packet_purchaser, update_from_ws_config, false),
    ok = pp_config:reset_config(),

    Empty = #{joins => [], routing => []},

    console_callback:update_config(WSPid, OneMapped),
    timer:sleep(500),
    ?assertEqual({ok, Empty}, pp_config:get_config()),

    console_callback:update_config(WSPid, TwoMapped),
    timer:sleep(500),
    ?assertEqual({ok, Empty}, pp_config:get_config()),

    console_callback:update_config(WSPid, TwoReMapped),
    timer:sleep(500),
    ?assertEqual({ok, Empty}, pp_config:get_config()),

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
        {error, {buying_inactive, ?NET_ID}},
        pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())
    ),
    ?assertEqual(
        {error, {buying_inactive, ?NET_ID}},
        pp_sc_packet_handler:handle_offer(MakeOfferFun(), self())
    ),
    ?assertEqual(
        {error, {buying_inactive, ?NET_ID}},
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
