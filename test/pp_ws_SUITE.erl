-module(pp_ws_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    ws_init_test/1,
    ws_receive_packet_test/1,
    ws_console_update_config_test/1
]).

-include_lib("eunit/include/eunit.hrl").

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
        ws_console_update_config_test
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

    ok = pp_console_ws_worker:send(<<"packet_one">>),
    {ok, <<"packet_one">>} = test_utils:ws_rcv(),

    ok = pp_console_ws_worker:send(<<"packet_two">>),
    {ok, <<"packet_two">>} = test_utils:ws_rcv(),

    ok = pp_console_ws_worker:send(<<"packet_three">>),
    {ok, <<"packet_three">>} = test_utils:ws_rcv(),

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
