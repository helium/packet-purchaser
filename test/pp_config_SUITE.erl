-module(pp_config_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    unfilled_config_test/1,
    lookup_join_multiple_configurations_test/1,
    default_net_id_protocol_version_test/1
]).

-include_lib("eunit/include/eunit.hrl").
-include("http_protocol.hrl").

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
        lookup_join_multiple_configurations_test,
        default_net_id_protocol_version_test
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
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => 1234,
            <<"configs">> => [
                #{
                    <<"joins">> => [],
                    <<"devaddrs">> => [],
                    <<"active">> => false,
                    <<"multi_buy">> => 0,

                    <<"protocol">> => <<"http">>,
                    <<"protocol_version">> => <<"1.1">>,
                    <<"http_auth_header">> => null,
                    <<"http_dedupe_timeout">> => 500,
                    <<"http_endpoint">> => <<>>,
                    <<"http_flow_type">> => <<"async">>
                }
            ]
        }
    ]),

    ok.

lookup_join_multiple_configurations_test(_Config) ->
    DevEUI = <<"0x0000000000000001">>,
    AppEUI = <<"0x0000000000000002">>,

    DevEUINum = pp_config_v2:hex_to_num(DevEUI),
    AppEUINum = pp_config_v2:hex_to_num(AppEUI),

    pp_config:load_config([
        #{
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => 1234,
            <<"configs">> => [
                #{
                    <<"active">> => false,
                    <<"multi_buy">> => 0,
                    <<"joins">> => [
                        #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
                    ],
                    <<"devaddrs">> => []
                }
            ]
        }
    ]),
    %% 1 bad result, return the error
    ?assertMatch(
        {error, {not_configured, 1234}},
        pp_config:lookup_eui({eui, DevEUINum, AppEUINum})
    ),

    %% One valid, one invalid roamer for join
    pp_config:load_config([
        #{
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => 1234,
            <<"configs">> => [
                #{
                    <<"active">> => false,
                    <<"multi_buy">> => 0,
                    <<"joins">> => [
                        #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
                    ],
                    <<"devaddrs">> => [],
                    %%
                    <<"protocol">> => <<"http">>,
                    <<"protocol_version">> => <<"1.1">>,
                    <<"http_auth_header">> => null,
                    <<"http_dedupe_timeout">> => 500,
                    <<"http_endpoint">> => <<>>,
                    <<"http_flow_type">> => <<"async">>
                }
            ]
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => 5678,
            <<"configs">> => [
                #{
                    <<"active">> => true,
                    <<"address">> => <<"3.3.3.3">>,
                    <<"port">> => 3333,
                    <<"multi_buy">> => 1,
                    <<"joins">> => [
                        #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
                    ],
                    <<"devaddrs">> => [],
                    %%
                    <<"protocol">> => <<"http">>,
                    <<"protocol_version">> => <<"1.1">>,
                    <<"http_auth_header">> => null,
                    <<"http_dedupe_timeout">> => 500,
                    <<"http_endpoint">> => <<>>,
                    <<"http_flow_type">> => <<"async">>
                }
            ]
        }
    ]),
    %% 1 bad result, 1 good result, return good result
    ?assertMatch(
        {ok, [#{net_id := 5678}]},
        pp_config:lookup_eui({eui, DevEUINum, AppEUINum})
    ),

    ok.

default_net_id_protocol_version_test(_Config) ->
    application:set_env(packet_purchaser, force_net_id_protocol_version, #{}),
    pp_config:load_config([
        #{
            <<"active">> => false,
            <<"joins">> => [],
            <<"multi_buy">> => 0,
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => 1234,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"www.example.com">>
        }
    ]),

    %% Defaults to default
    {ok, #{routing := [Routing0]}} = pp_config:get_config(),
    Protocol0 = pp_config:protocol(Routing0),
    ?assertEqual(Protocol0#http_protocol.protocol_version, pv_1_1),

    %% Change default specifically for this net id
    application:set_env(packet_purchaser, force_net_id_protocol_version, #{1234 => pv_1_0}),
    pp_config:load_config([
        #{
            <<"active">> => false,
            <<"joins">> => [],
            <<"multi_buy">> => 0,
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => 1234,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"www.example.com">>
        }
    ]),

    %% Defaults to force
    {ok, #{routing := [Routing1]}} = pp_config:get_config(),
    Protocol1 = pp_config:protocol(Routing1),
    ?assertEqual(Protocol1#http_protocol.protocol_version, pv_1_0),

    ok.
