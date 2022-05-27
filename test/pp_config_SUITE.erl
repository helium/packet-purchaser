-module(pp_config_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    unfilled_config_test/1,
    lookup_join_multiple_configurations_test/1
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
        unfilled_config_test,
        lookup_join_multiple_configurations_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    ok = pp_config:init_ets(),
    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

unfilled_config_test(_Config) ->
    pp_config:load_config([
        #{
            <<"active">> => false,
            <<"joins">> => [],
            <<"multi_buy">> => 0,
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => 1234,
            <<"organization_id">> => <<"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee">>
        }
    ]),

    ok.

lookup_join_multiple_configurations_test(_Config) ->
    DevEUI = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI = <<0, 0, 0, 2, 0, 0, 0, 1>>,
    pp_config:load_config([
        #{
            <<"multi_buy">> => 0,
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => 1234,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
            ]
        }
    ]),
    %% 1 bad result, return the error
    ?assertMatch(
        {error, {not_configured, 1234}},
        pp_config:lookup_eui({eui, DevEUI, AppEUI})
    ),

    %% One valid, one invalid roamer for join
    pp_config:load_config([
        #{
            <<"multi_buy">> => 0,
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => 1234,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
            ]
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => 5678,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"multi_buy">> => 1,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
            ]
        }
    ]),
    %% 1 bad result, 1 good result, return good result
    ?assertMatch(
        {ok, [#{net_id := 5678}]},
        pp_config:lookup_eui({eui, DevEUI, AppEUI})
    ),

    ok.
