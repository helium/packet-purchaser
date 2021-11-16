-module(pp_ws_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    ws_init_test/1,
    ws_receive_packet_test/1,
    ws_console_send_org_add_test/1
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
        ws_console_send_org_add_test
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

ws_console_send_org_add_test(_Config) ->
    {ok, WSPid} = test_utils:ws_init(),
    OneMapped = [
        #{
            <<"name">> => "two",
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337
        }
    ],
    WSPid ! {reset_config, OneMapped},
    timer:sleep(1000),
    {state, Filename, Config} = sys:get_state(whereis(pp_config)),
    ct:print("config:~n~p~n~p~nws_worker: ~p", [Filename, Config, whereis(pp_console_ws_worker)]),

    ok.
