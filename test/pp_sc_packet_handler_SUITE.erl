-module(pp_sc_packet_handler_SUITE).

-export([
    all/0,
    groups/0,
    init_per_testcase/2,
    end_per_testcase/2,
    init_per_group/2,
    end_per_group/2
]).

-export([
    join_net_id_offer_test/1,
    join_net_id_packet_test/1,
    net_ids_map_offer_test/1,
    net_ids_map_packet_test/1,
    net_ids_no_config_test/1,
    single_hotspot_multi_net_id_test/1,
    config_inactive_test/1,
    udp_change_location_test/1,
    multi_buy_join_test/1,
    multi_buy_packet_test/1,
    multi_buy_eviction_test/1,
    multi_buy_worst_case_stress_test/1,
    packet_websocket_test/1,
    packet_websocket_inactive_test/1,
    join_websocket_test/1,
    join_websocket_inactive_test/1,
    stop_start_purchasing_net_id_packet_test/1,
    stop_start_purchasing_net_id_join_test/1,
    drop_not_configured_orgs_packet_test/1,
    drop_not_configured_orgs_join_test/1,
    %% http_test/1,
    http_sync_uplink_join_test/1,
    http_async_uplink_join_test/1,
    http_uplink_packet_test/1,
    http_uplink_packet_no_roaming_agreement_test/1,
    http_multiple_gateways_test/1,
    http_multiple_gateways_single_shot_test/1,
    http_sync_downlink_test/1,
    http_async_downlink_test/1,
    http_class_c_downlink_test/1,
    http_uplink_packet_late_test/1,
    http_auth_header_test/1,
    http_protocol_version_test/1,
    %%
    udp_multiple_joins_test/1,
    udp_multiple_joins_same_dest_test/1,
    http_multiple_joins_test/1,
    http_multiple_joins_same_dest_test/1,
    http_overlapping_devaddr_test/1,
    %%
    multiple_protocol_single_gateway_downlink_test/1
]).

-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").

%% NetIDs
-define(NET_ID_ACTILITY, 16#000002).
-define(NET_ID_ACTILITY_BIN, <<"0x000002">>).

-define(NET_ID_COMCAST, 16#000022).
-define(NET_ID_COMCAST_2, 16#60001C).
-define(NET_ID_EXPERIMENTAL, 16#000000).
-define(NET_ID_ORANGE, 16#00000F).
-define(NET_ID_TEKTELIC, 16#000037).

%% DevAddrs

% pp_utils:hex_to_binary(<<"04ABCDEF">>)
-define(DEVADDR_ACTILITY, <<4, 171, 205, 239>>).
-define(DEVADDR_ACTILITY_BIN, <<"0x04ABCDEF">>).

% pp_utils:hex_to_binary(<<"45000042">>)
-define(DEVADDR_COMCAST, <<69, 0, 0, 66>>).
% pp_utils:hex_to_binary(<<"0000041">>)
-define(DEVADDR_EXPERIMENTAL, <<0, 0, 0, 42>>).
%pp_utils:hex_to_binary(<<"1E123456">>)
-define(DEVADDR_ORANGE, <<30, 18, 52, 86>>).
% pp_utils:hex_to_binary(<<"6E123456">>)
-define(DEVADDR_TEKTELIC, <<110, 18, 52, 86>>).

-define(CONSOLE_IP_PORT, <<"127.0.0.1:3001">>).
-define(CONSOLE_WS_URL, <<"ws://", ?CONSOLE_IP_PORT/binary, "/websocket">>).

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
        {group, chain_alive},
        {group, chain_dead}
    ].

groups() ->
    [
        {chain_alive, all_tests()},
        {chain_dead, all_tests()}
    ].

all_tests() ->
    [
        join_net_id_offer_test,
        join_net_id_packet_test,
        net_ids_map_offer_test,
        net_ids_map_packet_test,
        net_ids_no_config_test,
        single_hotspot_multi_net_id_test,
        config_inactive_test,
        multi_buy_join_test,
        udp_change_location_test,
        multi_buy_packet_test,
        multi_buy_eviction_test,
        %%
        packet_websocket_test,
        packet_websocket_inactive_test,
        join_websocket_test,
        join_websocket_inactive_test,
        %% multi_buy_worst_case_stress_test
        stop_start_purchasing_net_id_packet_test,
        stop_start_purchasing_net_id_join_test,
        drop_not_configured_orgs_packet_test,
        drop_not_configured_orgs_join_test,
        %% http
        http_sync_uplink_join_test,
        http_async_uplink_join_test,
        http_sync_downlink_test,
        http_async_downlink_test,
        http_class_c_downlink_test,
        http_uplink_packet_test,
        http_uplink_packet_no_roaming_agreement_test,
        http_uplink_packet_late_test,
        http_multiple_gateways_test,
        http_multiple_gateways_single_shot_test,
        http_auth_header_test,
        http_protocol_version_test,
        %% multiple_buyers
        udp_multiple_joins_test,
        udp_multiple_joins_same_dest_test,
        http_multiple_joins_test,
        http_multiple_joins_same_dest_test,
        http_overlapping_devaddr_test,
        %%
        multiple_protocol_single_gateway_downlink_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_group(chain_alive, Config) ->
    ok = application:set_env(
        packet_purchaser,
        is_chain_dead,
        false,
        [{persistent, true}]
    ),
    [{is_chain_dead, false} | Config];
init_per_group(chain_dead, Config) ->
    ok = application:set_env(
        packet_purchaser,
        is_chain_dead,
        true,
        [{persistent, true}]
    ),
    [{is_chain_dead, true} | Config];
init_per_group(_GroupName, Config) ->
    Config.

init_per_testcase(join_websocket_inactive_test = TestCase, Config0) ->
    Config1 = [
        {console_api, [{auto_connect, false}]}
        | Config0
    ],
    test_utils:init_per_testcase(TestCase, Config1);
init_per_testcase(packet_websocket_inactive_test = TestCase, Config0) ->
    Config1 = [
        {console_api, [{auto_connect, false}]}
        | Config0
    ],
    test_utils:init_per_testcase(TestCase, Config1);
init_per_testcase(TestCase, Config) ->
    %% NOTE: The test location service is setup to always return the same
    %% location. When we test with the chain, none of the keys generated are
    %% asserted. Because of different systems, when a location is not found, the
    %% keys are not included in payloads we send out. To keep the chain_alive
    %% chain_dead groups of this suite in alignment, we're telling the location
    %% service to never return a location.
    application:set_env(packet_purchaser, test_location_not_found, true),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_group(_GroupName, _Config) ->
    ok = application:set_env(
        packet_purchaser,
        is_chain_dead,
        false,
        [{persistent, true}]
    ),
    ok.

end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

drop_not_configured_orgs_packet_test(_Config) ->
    MakePacketOffer = fun() ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        test_utils:packet_offer(PubKeyBin, ?DEVADDR_ACTILITY)
    end,

    pp_config:load_config([
        #{
            <<"active">> => false,
            <<"joins">> => [],
            <<"multi_buy">> => 0,
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => ?NET_ID_ACTILITY
        }
    ]),

    Offer = MakePacketOffer(),
    ?assertMatch(
        {error, {not_configured, ?NET_ID_ACTILITY}},
        pp_sc_packet_handler:handle_offer(Offer, self())
    ),

    ok.

drop_not_configured_orgs_join_test(_Config) ->
    DevEUI = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    DevNonce = crypto:strong_rand_bytes(2),
    AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    JoinOffer = test_utils:join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI),

    %% Single non-buying roamer for join
    pp_config:load_config([
        #{
            <<"active">> => false,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
            ],
            <<"multi_buy">> => 0,
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => ?NET_ID_ACTILITY
        }
    ]),
    %% Offer is rejected for single roamer
    ?assertMatch(
        {error, {not_configured, ?NET_ID_ACTILITY}},
        pp_sc_packet_handler:handle_offer(JoinOffer, self())
    ),

    %% One valid, one invalid roamer for join
    pp_config:load_config([
        #{
            <<"active">> => false,
            <<"multi_buy">> => 0,
            <<"name">> => <<"Test Onboarding">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
            ]
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"multi_buy">> => 1,
            <<"active">> => true,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
            ]
        }
    ]),
    %% Offer is purchased for single configured roamer
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(JoinOffer, self())),

    ok.

http_auth_header_test(_Config) ->
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, ?DEVADDR_COMCAST, 0, Routing, #{
        dont_encode => true
    }),

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_dedupe_timeout">> => 50,
            <<"http_auth_header">> => <<"Basic: testing">>,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    ok = start_uplink_listener(#{port => 3002, callback_args => #{forward => self()}}),

    ok = pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

    {ok, _, Request, _} = pp_lns:http_rcv(),
    Headers = elli_request:headers(Request),
    ?assertEqual(<<"Basic: testing">>, proplists:get_value(<<"Authorization">>, Headers)),

    ok = pp_lns:not_http_rcv(250),

    ok.

http_protocol_version_test(_Config) ->
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    MakePacket = fun(Fcnt) ->
        test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, ?DEVADDR_COMCAST, Fcnt, Routing, #{
            dont_encode => true
        })
    end,

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_dedupe_timeout">> => 50,
            <<"http_auth_header">> => <<"Basic: testing">>,
            <<"http_flow_type">> => <<"sync">>,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    ok = start_roamer_listener(),
    ok = start_forwarder_listener(),

    %% The default protocol is 1.1.
    ok = pp_sc_packet_handler:handle_packet(MakePacket(0), erlang:system_time(millisecond), self()),
    {ok, Uplink1, _, _} = pp_lns:http_rcv(),
    ?assertEqual(maps:get(<<"ProtocolVersion">>, Uplink1), <<"1.1">>),

    %% We can change it with the config
    application:set_env(packet_purchaser, http_protocol_version, <<"1.0">>),
    pp_config:change_http_protocol_version(?NET_ID_ACTILITY, pv_1_0),
    ok = pp_sc_packet_handler:handle_packet(MakePacket(1), erlang:system_time(millisecond), self()),
    {ok, Uplink2, _, _} = pp_lns:http_rcv(),
    ?assertEqual(maps:get(<<"ProtocolVersion">>, Uplink2), <<"1.0">>),

    %% We can change it back
    pp_config:change_http_protocol_version(?NET_ID_ACTILITY, pv_1_1),
    ok = pp_sc_packet_handler:handle_packet(MakePacket(2), erlang:system_time(millisecond), self()),
    {ok, Uplink3, _, _} = pp_lns:http_rcv(),
    ?assertEqual(maps:get(<<"ProtocolVersion">>, Uplink3), <<"1.1">>),

    %% Responses are whatever version was sent to us.

    %% NOTE: We need to insert the transaction and handler here because we're
    %% only simulating downlinks. In a normal flow, these details would be
    %% filled during the uplink process.
    TransactionID = 2177,
    Token = pp_roaming_protocol:make_uplink_token(
        PubKeyBin,
        'US915',
        1234,
        <<"www.example.com">>,
        sync
    ),

    ok = pp_roaming_downlink:insert_handler(TransactionID, self()),
    SendDownlinkWithVersion = fun(ProtocolVersion) ->
        DownlinkBody = #{
            <<"ProtocolVersion">> => ProtocolVersion,
            <<"MessageType">> => <<"XmitDataReq">>,
            <<"ReceiverID">> => <<"0xC00053">>,
            <<"SenderID">> => ?NET_ID_ACTILITY_BIN,
            <<"DLMetaData">> => #{
                <<"ClassMode">> => <<"C">>,
                <<"DLFreq2">> => 915.0,
                <<"DataRate2">> => 0,
                <<"DevEUI">> => <<"0xaabbffccfeeff001">>,
                <<"FNSULToken">> => Token,
                <<"HiPriorityFlag">> => false,
                <<"RXDelay1">> => 0
            },
            <<"PHYPayload">> => <<"0x1234">>,
            <<"TransactionID">> => TransactionID
        },

        {ok, 200, _Headers, Resp} = hackney:post(
            <<"http://127.0.0.1:3003/downlink">>,
            [{<<"Host">>, <<"localhost">>}],
            jsx:encode(DownlinkBody),
            [with_body]
        ),
        ?assertEqual(maps:get(<<"ProtocolVersion">>, jsx:decode(Resp)), ProtocolVersion)
    end,

    SendDownlinkWithVersion(<<"1.1">>),
    SendDownlinkWithVersion(<<"1.0">>),

    ok.

http_multiple_joins_test(_Config) ->
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, ?DEVADDR_COMCAST, 0, Routing, #{
        dont_encode => true
    }),

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_dedupe_timeout">> => 50,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3003/uplink">>,
            <<"http_dedupe_timeout">> => 50,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    ok = start_uplink_listener(#{port => 3002, callback_args => #{forward => self()}}),
    ok = start_uplink_listener(#{port => 3003, callback_args => #{forward => self()}}),

    ok = pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

    {ok, _, _, _} = pp_lns:http_rcv(),
    {ok, _, _, _} = pp_lns:http_rcv(),
    ok = pp_lns:not_http_rcv(250),

    ok.

http_multiple_joins_same_dest_test(_Config) ->
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, ?DEVADDR_COMCAST, 0, Routing, #{
        dont_encode => true
    }),

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_dedupe_timeout">> => 50,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_dedupe_timeout">> => 50,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    ok = start_uplink_listener(#{port => 3002, callback_args => #{forward => self()}}),
    ok = pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

    {ok, #{<<"ReceiverID">> := ReceiverOne}, _, _} = pp_lns:http_rcv(),
    {ok, #{<<"ReceiverID">> := ReceiverTwo}, _, _} = pp_lns:http_rcv(),
    ok = pp_lns:not_http_rcv(250),

    ?assertNotEqual(ReceiverOne, ReceiverTwo),

    ok.

http_overlapping_devaddr_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, ?DEVADDR_COMCAST, 0, #{
        dont_encode => true
    }),

    DevAddrRangeSingle = #{<<"lower">> => <<"0x45000042">>, <<"upper">> => <<"0x45000042">>},
    DevAddrInRange = #{<<"lower">> => <<"0x45000040">>, <<"upper">> => <<"0x45000044">>},

    %% Overlapping Devaddrs, but going to different endpoints
    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"configs">> => [
                #{
                    <<"protocol">> => <<"http">>,
                    <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
                    <<"http_dedupe_timeout">> => 50,
                    <<"joins">> => [],
                    <<"devaddrs">> => [DevAddrRangeSingle]
                },
                #{
                    <<"protocol">> => <<"http">>,
                    <<"http_endpoint">> => <<"http://127.0.0.1:3003/uplink">>,
                    <<"http_dedupe_timeout">> => 50,
                    <<"joins">> => [],
                    <<"devaddrs">> => [DevAddrInRange]
                }
            ]
        }
    ]),

    ok = start_uplink_listener(#{port => 3002}),
    ok = start_uplink_listener(#{port => 3003}),
    ok = pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

    {ok, #{<<"ReceiverID">> := ReceiverOne}, _, _} = pp_lns:http_rcv(),
    {ok, #{<<"ReceiverID">> := ReceiverTwo}, _, _} = pp_lns:http_rcv(),
    ok = pp_lns:not_http_rcv(250),

    %% Receiver ID must be the same because DevAddr is explicitly partitioned by
    %% NetID, unlike Join EUI. And we got 2 requests.
    ?assertEqual(ReceiverOne, ReceiverTwo),

    ok.

http_sync_uplink_join_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ok = start_uplink_listener(),

    %% NOTE: Leading 00 are important in this test.
    %% We want to make sure EUI are encoded with the correct number of bytes.
    DevEUI = <<"00BBCCDDEEFF0011">>,
    AppEUI = <<"1122334455667788">>,

    SendPacketFun = fun(DevAddr) ->
        Routing = blockchain_helium_packet_v1:make_routing_info(
            {
                eui,
                erlang:binary_to_integer(DevEUI, 16),
                erlang:binary_to_integer(AppEUI, 16)
            }
        ),
        Packet = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            DevAddr,
            0,
            Routing,
            #{dont_encode => true}
        ),
        GatewayTime = erlang:system_time(millisecond),
        pp_sc_packet_handler:handle_packet(Packet, GatewayTime, self()),
        {ok, Packet, GatewayTime}
    end,

    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"configs">> => [
                #{
                    <<"protocol">> => <<"http">>,
                    <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
                    <<"http_flow_type">> => <<"sync">>,
                    <<"joins">> => [
                        #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
                    ],
                    <<"devaddrs">> => []
                }
            ]
        }
    ]),

    %% ===================================================================
    %% Done with setup.

    %% 1. Send a join uplink
    {ok, SCPacket, GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),

    PacketTime = blockchain_helium_packet_v1:timestamp(Packet),
    Token = pp_roaming_protocol:make_uplink_token(
        PubKeyBin,
        'US915',
        PacketTime,
        <<"http://127.0.0.1:3002/uplink">>,
        sync
    ),

    %% 2. Expect a PRStartReq to the lns
    {
        ok,
        #{<<"TransactionID">> := TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, RespBody}
    } = pp_lns:http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => pp_utils:binary_to_hexstring(
                blockchain_helium_packet_v1:payload(Packet)
            ),
            <<"ULMetaData">> => #{
                <<"DevEUI">> => <<"0x", DevEUI/binary>>,
                <<"DataRate">> => pp_lorawan:datarate_to_index(
                    Region,
                    blockchain_helium_packet_v1:datarate(Packet)
                ),
                <<"ULFreq">> => blockchain_helium_packet_v1:frequency(Packet),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => pp_utils:format_time(GatewayTime),

                <<"FNSULToken">> => Token,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => erlang:trunc(
                            blockchain_helium_packet_v1:signal_strength(Packet)
                        ),
                        <<"SNR">> => blockchain_helium_packet_v1:snr(Packet),
                        <<"DLAllowed">> => true,
                        <<"ID">> => pp_utils:binary_to_hexstring(
                            pp_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    %% 3. Expect a PRStartAns from the lns
    %%   - With DevEUI
    %%   - With PHyPayload
    case
        test_utils:match_map(
            #{
                <<"ProtocolVersion">> => <<"1.1">>,
                <<"TransactionID">> => TransactionID,
                <<"SenderID">> => ?NET_ID_ACTILITY_BIN,
                <<"ReceiverID">> => <<"0xC00053">>,
                <<"MessageType">> => <<"PRStartAns">>,
                <<"Result">> => #{
                    <<"ResultCode">> => <<"Success">>
                },
                <<"PHYPayload">> => pp_utils:binary_to_hexstring(<<"join_accept_payload">>),
                <<"DevEUI">> => <<"0x", DevEUI/binary>>,
                <<"DLMetaData">> => #{
                    <<"DLFreq1">> => blockchain_helium_packet_v1:frequency(Packet),
                    <<"FNSULToken">> => Token,
                    <<"Lifetime">> => 0,
                    <<"DataRate1">> => fun erlang:is_integer/1
                }
            },
            RespBody
        )
    of
        true -> ok;
        {false, Reason} -> ct:fail({http_response, Reason})
    end,

    %% 4. Expect downlink queued for gateway
    ok = gateway_expect_downlink(fun(SCResp) ->
        Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
        ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
        ok
    end),

    ok.

http_async_uplink_join_test(_Config) ->
    %%
    %% Forwarder : packet-purchaser
    %% Roamer    : partner-lns
    %%
    ok = start_forwarder_listener(),
    ok = start_roamer_listener(),

    %% 1. Get a gateway to send from
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    DevEUI = <<"AABBCCDDEEFF0011">>,
    AppEUI = <<"1122334455667788">>,

    SendPacketFun = fun(DevAddr) ->
        Routing = blockchain_helium_packet_v1:make_routing_info(
            {
                eui,
                erlang:binary_to_integer(DevEUI, 16),
                erlang:binary_to_integer(AppEUI, 16)
            }
        ),
        Packet = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            DevAddr,
            0,
            Routing,
            #{dont_encode => true}
        ),
        GatewayTime = erlang:system_time(millisecond),
        pp_sc_packet_handler:handle_packet(Packet, GatewayTime, self()),
        {ok, Packet, GatewayTime}
    end,

    %% 2. load Roamer into the config
    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_flow_type">> => <<"async">>,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
            ]
        }
    ]),

    %% 3. send packet
    {ok, SCPacket, GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),

    PacketTime = blockchain_helium_packet_v1:timestamp(Packet),
    Token = pp_roaming_protocol:make_uplink_token(
        PubKeyBin,
        'US915',
        PacketTime,
        <<"http://127.0.0.1:3002/uplink">>,
        async
    ),

    %% 4. Roamer receive http uplink
    {ok, #{<<"TransactionID">> := TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}}} = roamer_expect_uplink_data(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => pp_utils:binary_to_hexstring(
                blockchain_helium_packet_v1:payload(Packet)
            ),
            <<"ULMetaData">> => #{
                <<"DevEUI">> => <<"0x", DevEUI/binary>>,
                <<"DataRate">> => pp_lorawan:datarate_to_index(
                    Region,
                    blockchain_helium_packet_v1:datarate(Packet)
                ),
                <<"ULFreq">> => blockchain_helium_packet_v1:frequency(Packet),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => pp_utils:format_time(GatewayTime),

                <<"FNSULToken">> => Token,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => erlang:trunc(
                            blockchain_helium_packet_v1:signal_strength(Packet)
                        ),
                        <<"SNR">> => blockchain_helium_packet_v1:snr(Packet),
                        <<"DLAllowed">> => true,
                        <<"ID">> => pp_utils:binary_to_hexstring(
                            pp_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    %% 5. Forwarder receive 200 response
    ok = forwarder_expect_response(200),

    %% 6. Forwarder receive http downlink
    {ok, _Data} = forwarder_expect_downlink_data(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"TransactionID">> => TransactionID,
        <<"SenderID">> => ?NET_ID_ACTILITY_BIN,
        <<"ReceiverID">> => <<"0xC00053">>,
        <<"MessageType">> => <<"PRStartAns">>,
        <<"Result">> => #{
            <<"ResultCode">> => <<"Success">>
        },
        <<"PHYPayload">> => pp_utils:binary_to_hexstring(<<"join_accept_payload">>),
        <<"DevEUI">> => <<"0x", DevEUI/binary>>,
        <<"DLMetaData">> => #{
            <<"DataRate1">> => fun erlang:is_integer/1,
            <<"FNSULToken">> => Token,
            <<"Lifetime">> => 0,
            <<"DLFreq1">> => blockchain_helium_packet_v1:frequency(Packet)
        }
    }),
    %% 7. Roamer receive 200 response
    ok = roamer_expect_response(200),

    %% 8. Gateway receive queued sc downlink
    ok = gateway_expect_downlink(fun(SCResp) ->
        Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
        ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
        ok
    end),

    ok.

http_sync_downlink_test(_Config) ->
    ok = start_forwarder_listener(),

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = "SF10BW125",
    TransactionID = 23,

    Token = pp_roaming_protocol:make_uplink_token(
        PubKeyBin,
        'US915',
        DownlinkTimestamp,
        <<"http://127.0.0.1:3002/uplink">>,
        sync
    ),
    RXDelay = 1,

    DownlinkBody = #{
        'ProtocolVersion' => <<"1.1">>,
        'SenderID' => pp_utils:binary_to_hexstring(?NET_ID_ACTILITY),
        'ReceiverID' => <<"0xC00053">>,
        'TransactionID' => TransactionID,
        'MessageType' => <<"XmitDataReq">>,
        'PHYPayload' => pp_utils:binary_to_hexstring(DownlinkPayload),
        'DLMetaData' => #{
            'DevEUI' => <<"0xaabbffccfeeff001">>,
            'DLFreq1' => DownlinkFreq,
            'DataRate1' => 0,
            'RXDelay1' => RXDelay,
            'FNSULToken' => Token,
            'GWInfo' => [
                #{'ULToken' => libp2p_crypto:bin_to_b58(PubKeyBin)}
            ],
            'ClassMode' => <<"A">>,
            'HiPriorityFlag' => false
        }
    },

    %% NOTE: We need to insert the transaction and handler here because we're
    %% only simulating downlinks. In a normal flow, these details would be
    %% filled during the uplink process.

    ok = pp_roaming_downlink:insert_handler(PubKeyBin, self()),
    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_flow_type">> => <<"sync">>
        }
    ]),

    {ok, 200, _Headers, Resp} = hackney:post(
        <<"http://127.0.0.1:3003/downlink">>,
        [{<<"Host">>, <<"localhost">>}],
        jsx:encode(DownlinkBody),
        [with_body]
    ),

    case
        test_utils:match_map(
            #{
                <<"ProtocolVersion">> => <<"1.1">>,
                <<"TransactionID">> => TransactionID,
                <<"SenderID">> => <<"0xC00053">>,
                <<"ReceiverID">> => pp_utils:binary_to_hexstring(?NET_ID_ACTILITY),
                <<"MessageType">> => <<"XmitDataAns">>,
                <<"Result">> => #{
                    <<"ResultCode">> => <<"Success">>
                },
                <<"DLFreq1">> => DownlinkFreq
            },
            jsx:decode(Resp)
        )
    of
        true -> ok;
        {false, Reason} -> ct:fail({http_response, Reason})
    end,

    ok = gateway_expect_downlink(fun(SCResp) ->
        Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
        ?assertEqual(DownlinkPayload, blockchain_helium_packet_v1:payload(Downlink)),
        ?assertEqual(
            pp_utils:uint32(DownlinkTimestamp + (RXDelay * 1_000_000)),
            blockchain_helium_packet_v1:timestamp(Downlink)
        ),
        ?assertEqual(DownlinkFreq, blockchain_helium_packet_v1:frequency(Downlink)),
        ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
        ?assertEqual(DownlinkDatr, blockchain_helium_packet_v1:datarate(Downlink)),
        ok
    end),
    ok.

http_async_downlink_test(_Config) ->
    %%
    %% Forwarder : packet-purchaser
    %% Roamer    : partner-lns
    %%
    ok = start_forwarder_listener(),
    ok = start_roamer_listener(),

    %% 1. Get a gateway to send from
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% 2. insert sc handler and config
    TransactionID = 23,
    ok = pp_roaming_downlink:insert_handler(PubKeyBin, self()),

    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_flow_type">> => <<"async">>
        }
    ]),

    %% 3. send downlink
    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = "SF10BW125",

    Token = pp_roaming_protocol:make_uplink_token(
        PubKeyBin,
        'US915',
        DownlinkTimestamp,
        <<"http://127.0.0.1:3002/uplink">>,
        async
    ),
    RXDelay = 1,

    DownlinkBody = #{
        'ProtocolVersion' => <<"1.1">>,
        'SenderID' => pp_utils:hexstring(?NET_ID_ACTILITY),
        'ReceiverID' => <<"0xC00053">>,
        'TransactionID' => TransactionID,
        'MessageType' => <<"XmitDataReq">>,
        'PHYPayload' => pp_utils:binary_to_hexstring(DownlinkPayload),
        'DLMetaData' => #{
            'DevEUI' => <<"0xaabbffccfeeff001">>,
            'DLFreq1' => DownlinkFreq,
            'DataRate1' => 0,
            'RXDelay1' => RXDelay,
            'FNSULToken' => Token,
            'GWInfo' => [
                #{'ULToken' => libp2p_crypto:bin_to_b58(PubKeyBin)}
            ],
            'ClassMode' => <<"A">>,
            'HiPriorityFlag' => false
        }
    },

    _ = hackney:post(
        <<"http://127.0.0.1:3003/downlink">>,
        [{<<"Host">>, <<"localhost">>}],
        jsx:encode(DownlinkBody),
        [with_body]
    ),

    %% 4. forwarder receive http downlink
    {ok, #{<<"TransactionID">> := TransactionID}} = forwarder_expect_downlink_data(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"SenderID">> => pp_utils:hexstring(?NET_ID_ACTILITY),
        <<"ReceiverID">> => <<"0xC00053">>,
        <<"TransactionID">> => TransactionID,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> => pp_utils:binary_to_hexstring(DownlinkPayload),
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0xaabbffccfeeff001">>,
            <<"DLFreq1">> => DownlinkFreq,
            <<"DataRate1">> => 0,
            <<"RXDelay1">> => RXDelay,
            <<"FNSULToken">> => Token,
            <<"GWInfo">> => [
                #{<<"ULToken">> => libp2p_crypto:bin_to_b58(PubKeyBin)}
            ],
            <<"ClassMode">> => <<"A">>,
            <<"HiPriorityFlag">> => false
        }
    }),

    %% 5. roamer expect 200 response
    ok = roamer_expect_response(200),

    %% 6. roamer receives http downlink ack (xmitdata_ans)
    {ok, _Data} = roamer_expect_uplink_data(#{
        <<"DLFreq1">> => DownlinkFreq,
        <<"MessageType">> => <<"XmitDataAns">>,
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"ReceiverID">> => pp_utils:hexstring(?NET_ID_ACTILITY),
        <<"SenderID">> => <<"0xC00053">>,
        <<"Result">> => #{<<"ResultCode">> => <<"Success">>},
        <<"TransactionID">> => TransactionID
    }),

    %% 7. forwarder expects 200 response
    ok = forwarder_expect_response(200),

    %% 8. gateway receve quued sc downlink
    ok = gateway_expect_downlink(fun(SCResp) ->
        Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
        ?assertEqual(DownlinkPayload, blockchain_helium_packet_v1:payload(Downlink)),
        ?assertEqual(
            pp_utils:uint32(DownlinkTimestamp + (RXDelay * 1_000_000)),
            blockchain_helium_packet_v1:timestamp(Downlink)
        ),
        ?assertEqual(DownlinkFreq, blockchain_helium_packet_v1:frequency(Downlink)),
        ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
        ?assertEqual(DownlinkDatr, blockchain_helium_packet_v1:datarate(Downlink)),
        ok
    end),

    ok.

http_class_c_downlink_test(_Config) ->
    %%
    %% Forwarder : packet-purchaser
    %% Roamer    : partner-lns
    %%
    ok = start_forwarder_listener(),
    ok = start_roamer_listener(),

    %% 1. Get a gateway to send from
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% 2. insert sc handler and config
    TransactionID = 2176,
    ok = pp_roaming_downlink:insert_handler(PubKeyBin, self()),

    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_flow_type">> => <<"async">>
        }
    ]),

    %% 3. send downlink
    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = "SF10BW125",

    Token = pp_roaming_protocol:make_uplink_token(
        PubKeyBin,
        'US915',
        DownlinkTimestamp,
        <<"http://127.0.0.1:3002/uplink">>,
        async
    ),
    RXDelay = 0,

    DownlinkBody = #{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"ReceiverID">> => <<"0xC00053">>,
        <<"SenderID">> => ?NET_ID_ACTILITY_BIN,
        <<"DLMetaData">> => #{
            <<"ClassMode">> => <<"C">>,
            <<"DLFreq2">> => DownlinkFreq,
            <<"DataRate2">> => 0,
            <<"DevEUI">> => <<"0xaabbffccfeeff001">>,
            <<"FNSULToken">> => Token,
            <<"HiPriorityFlag">> => false,
            <<"RXDelay1">> => 0
        },
        <<"PHYPayload">> => pp_utils:binary_to_hexstring(DownlinkPayload),
        <<"TransactionID">> => TransactionID
    },

    _ = hackney:post(
        <<"http://127.0.0.1:3003/downlink">>,
        [{<<"Host">>, <<"localhost">>}],
        jsx:encode(DownlinkBody),
        [with_body]
    ),

    %% 4. forwarder receive http downlink
    {ok, #{<<"TransactionID">> := TransactionID}} = forwarder_expect_downlink_data(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"SenderID">> => pp_utils:hexstring(?NET_ID_ACTILITY),
        <<"ReceiverID">> => <<"0xC00053">>,
        <<"TransactionID">> => 2176,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> => pp_utils:binary_to_hexstring(DownlinkPayload),
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0xaabbffccfeeff001">>,
            <<"DLFreq2">> => DownlinkFreq,
            <<"DataRate2">> => 0,
            <<"RXDelay1">> => RXDelay,
            <<"FNSULToken">> => Token,
            <<"ClassMode">> => <<"C">>,
            <<"HiPriorityFlag">> => false
        }
    }),

    %% 5. roamer expect 200 response
    ok = roamer_expect_response(200),

    %% 6. roamer receives http downlink ack (xmitdata_ans)
    {ok, _Data} = roamer_expect_uplink_data(#{
        <<"DLFreq2">> => DownlinkFreq,
        <<"MessageType">> => <<"XmitDataAns">>,
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"ReceiverID">> => pp_utils:hexstring(?NET_ID_ACTILITY),
        <<"SenderID">> => <<"0xC00053">>,
        <<"Result">> => #{<<"ResultCode">> => <<"Success">>},
        <<"TransactionID">> => TransactionID
    }),

    %% 7. forwarder expects 200 response
    ok = forwarder_expect_response(200),

    %% 8. gateway receve quued sc downlink
    ok = gateway_expect_downlink(fun(SCResp) ->
        Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
        ?assertEqual(DownlinkPayload, blockchain_helium_packet_v1:payload(Downlink)),
        ?assertEqual(
            immediate,
            blockchain_helium_packet_v1:timestamp(Downlink)
        ),
        ?assertEqual(DownlinkFreq, blockchain_helium_packet_v1:frequency(Downlink)),
        ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
        ?assertEqual(DownlinkDatr, blockchain_helium_packet_v1:datarate(Downlink)),
        ok
    end),

    ok.

http_uplink_packet_no_roaming_agreement_test(_Config) ->
    %% When receiving a response that there is no roaming agreement for a NetID,
    %% we should stop purchasing for that NetID.
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ok = start_uplink_listener(#{
        callback_args => #{
            response => #{
                <<"SenderID">> => <<"000002">>,
                <<"ReceiverID">> => <<"C00053">>,
                <<"ProtocolVersion">> => <<"1.1">>,
                <<"TransactionID">> => 601913476,
                <<"MessageType">> => <<"PRStartAns">>,
                <<"Result">> => #{
                    <<"ResultCode">> => <<"NoRoamingAgreement">>,
                    <<"Description">> => <<"There is no roaming agreement between the operators">>
                }
            }
        }
    }),

    SendPacketFun = fun(DevAddr, FrameCount) ->
        Packet = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            DevAddr,
            FrameCount,
            #{dont_encode => true}
        ),
        GatewayTime = erlang:system_time(millisecond),
        pp_sc_packet_handler:handle_packet(Packet, GatewayTime, self()),
        {ok, Packet, GatewayTime}
    end,

    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_flow_type">> => <<"sync">>
        }
    ]),
    {ok, SCPacket, GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY, 0),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    PacketTime = blockchain_helium_packet_v1:timestamp(Packet),

    %% First packet is purchased and sent to Roamer
    {
        ok,
        #{<<"TransactionID">> := _TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } = pp_lns:http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => pp_utils:binary_to_hexstring(
                blockchain_helium_packet_v1:payload(Packet)
            ),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => pp_lorawan:datarate_to_index(
                    Region,
                    blockchain_helium_packet_v1:datarate(Packet)
                ),
                <<"ULFreq">> => blockchain_helium_packet_v1:frequency(Packet),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => pp_utils:format_time(GatewayTime),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => erlang:trunc(
                            blockchain_helium_packet_v1:signal_strength(Packet)
                        ),
                        <<"SNR">> => blockchain_helium_packet_v1:snr(Packet),
                        <<"DLAllowed">> => true,
                        <<"ID">> => pp_utils:binary_to_hexstring(
                            pp_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, PubKeyBin, 'US915', PacketTime, <<"http://127.0.0.1:3002/uplink">>, sync},
        pp_roaming_protocol:parse_uplink_token(Token)
    ),

    timer:sleep(500),
    %% Second packet is not forwarded
    {ok, _SCPacket, _GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY, 1),
    ok = pp_lns:not_http_rcv(1000),

    ok.

http_uplink_packet_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ok = start_uplink_listener(),

    SendPacketFun = fun(DevAddr) ->
        Packet = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            DevAddr,
            0,
            #{dont_encode => true}
        ),
        GatewayTime = erlang:system_time(millisecond),
        pp_sc_packet_handler:handle_packet(Packet, GatewayTime, self()),
        {ok, Packet, GatewayTime}
    end,

    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_flow_type">> => <<"sync">>
        }
    ]),
    {ok, SCPacket, GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    PacketTime = blockchain_helium_packet_v1:timestamp(Packet),

    {
        ok,
        #{<<"TransactionID">> := _TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } = pp_lns:http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => pp_utils:binary_to_hexstring(
                blockchain_helium_packet_v1:payload(Packet)
            ),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => pp_lorawan:datarate_to_index(
                    Region,
                    blockchain_helium_packet_v1:datarate(Packet)
                ),
                <<"ULFreq">> => blockchain_helium_packet_v1:frequency(Packet),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => pp_utils:format_time(GatewayTime),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => erlang:trunc(
                            blockchain_helium_packet_v1:signal_strength(Packet)
                        ),
                        <<"SNR">> => blockchain_helium_packet_v1:snr(Packet),
                        <<"DLAllowed">> => true,
                        <<"ID">> => pp_utils:binary_to_hexstring(
                            pp_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, PubKeyBin, 'US915', PacketTime, <<"http://127.0.0.1:3002/uplink">>, sync},
        pp_roaming_protocol:parse_uplink_token(Token)
    ),

    ok.

http_uplink_packet_late_test(_Config) ->
    %% There's a builtin dedupe for http roaming, we want to make sure that
    %% gateways with high hold time don't cause the same packet to be sent again
    %% if they missed the dedupe window.

    %% One Gateway is going to be sending all the packets.
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    ok = start_uplink_listener(),

    SendPacketFun = fun(PubKeyBin, DevAddr) ->
        Packet = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            DevAddr,
            0,
            #{dont_encode => true}
        ),
        GatewayTime = erlang:system_time(millisecond),
        pp_sc_packet_handler:handle_packet(Packet, GatewayTime, self()),
        {ok, Packet, GatewayTime}
    end,

    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_dedupe_timeout">> => 10,
            <<"http_flow_type">> => <<"sync">>
        }
    ]),
    {ok, SCPacket, GatewayTime} = SendPacketFun(PubKeyBin1, ?DEVADDR_ACTILITY),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    PacketTime = blockchain_helium_packet_v1:timestamp(Packet),

    %% Wait past the timeout before sending another packet
    ok = timer:sleep(100),
    {ok, _, _} = SendPacketFun(PubKeyBin2, ?DEVADDR_ACTILITY),

    {
        ok,
        #{<<"TransactionID">> := _TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } = pp_lns:http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => pp_utils:binary_to_hexstring(
                blockchain_helium_packet_v1:payload(Packet)
            ),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => pp_lorawan:datarate_to_index(
                    Region,
                    blockchain_helium_packet_v1:datarate(Packet)
                ),
                <<"ULFreq">> => blockchain_helium_packet_v1:frequency(Packet),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => pp_utils:format_time(GatewayTime),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => erlang:trunc(
                            blockchain_helium_packet_v1:signal_strength(Packet)
                        ),
                        <<"SNR">> => blockchain_helium_packet_v1:snr(Packet),
                        <<"DLAllowed">> => true,
                        <<"ID">> => pp_utils:binary_to_hexstring(
                            pp_utils:pubkeybin_to_mac(PubKeyBin1)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, PubKeyBin1, 'US915', PacketTime, <<"http://127.0.0.1:3002/uplink">>, sync},
        pp_roaming_protocol:parse_uplink_token(Token)
    ),

    %% We should not get anotehr http request for the second packet that missed the window.
    ok = pp_lns:not_http_rcv(timer:seconds(1)),

    ok.

http_multiple_gateways_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    ok = start_uplink_listener(),

    SendPacketFun = fun(PubKeyBin, DevAddr, RSSI) ->
        Packet1 = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            DevAddr,
            0,
            #{dont_encode => true, rssi => RSSI}
        ),
        PacketTime1 = erlang:system_time(millisecond),
        pp_sc_packet_handler:handle_packet(Packet1, PacketTime1, self()),
        {ok, Packet1, PacketTime1}
    end,

    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>
        }
    ]),

    {ok, SCPacket1, GatewayTime1} = SendPacketFun(PubKeyBin1, ?DEVADDR_ACTILITY, -25.0),
    %% Sleep to ensure packets have different timing information
    timer:sleep(10),
    {ok, SCPacket2, _GatewayTime2} = SendPacketFun(PubKeyBin2, ?DEVADDR_ACTILITY, -30.0),
    Packet1 = blockchain_state_channel_packet_v1:packet(SCPacket1),
    PacketTime1 = blockchain_helium_packet_v1:timestamp(Packet1),
    Packet2 = blockchain_state_channel_packet_v1:packet(SCPacket2),
    Region = blockchain_state_channel_packet_v1:region(SCPacket1),

    {
        ok,
        #{<<"TransactionID">> := _TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } = pp_lns:http_rcv(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"SenderNSID">> => fun erlang:is_binary/1,
        <<"DedupWindowSize">> => fun erlang:is_integer/1,
        <<"TransactionID">> => fun erlang:is_number/1,
        <<"SenderID">> => <<"0xC00053">>,
        <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
        <<"MessageType">> => <<"PRStartReq">>,
        <<"PHYPayload">> => pp_utils:binary_to_hexstring(
            blockchain_helium_packet_v1:payload(Packet1)
        ),
        <<"ULMetaData">> => #{
            <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
            <<"DataRate">> => pp_lorawan:datarate_to_index(
                Region,
                blockchain_helium_packet_v1:datarate(Packet1)
            ),
            <<"ULFreq">> => blockchain_helium_packet_v1:frequency(Packet1),
            <<"RFRegion">> => erlang:atom_to_binary(Region),
            <<"RecvTime">> => pp_utils:format_time(GatewayTime1),
            <<"FNSULToken">> => fun erlang:is_binary/1,
            <<"GWCnt">> => 2,
            <<"GWInfo">> => [
                #{
                    <<"ID">> => pp_utils:binary_to_hexstring(pp_utils:pubkeybin_to_mac(PubKeyBin1)),
                    <<"RFRegion">> => erlang:atom_to_binary(Region),
                    <<"RSSI">> => erlang:trunc(
                        blockchain_helium_packet_v1:signal_strength(Packet1)
                    ),
                    <<"SNR">> => blockchain_helium_packet_v1:snr(Packet1),
                    <<"DLAllowed">> => true
                },
                #{
                    <<"ID">> => pp_utils:binary_to_hexstring(pp_utils:pubkeybin_to_mac(PubKeyBin2)),
                    <<"RFRegion">> => erlang:atom_to_binary(Region),
                    <<"RSSI">> => erlang:trunc(
                        blockchain_helium_packet_v1:signal_strength(Packet2)
                    ),
                    <<"SNR">> => blockchain_helium_packet_v1:snr(Packet2),
                    <<"DLAllowed">> => true
                }
            ]
        }
    }),

    %% Gateway with better RSSI should be chosen
    ?assertMatch(
        {ok, PubKeyBin1, 'US915', PacketTime1, <<"http://127.0.0.1:3002/uplink">>, sync},
        pp_roaming_protocol:parse_uplink_token(Token)
    ),

    ok.

http_multiple_gateways_single_shot_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    ok = start_uplink_listener(),

    SendPacketFun = fun(PubKeyBin, DevAddr, RSSI) ->
        Packet1 = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            DevAddr,
            0,
            #{dont_encode => true, rssi => RSSI}
        ),
        PacketTime1 = erlang:system_time(millisecond),
        pp_sc_packet_handler:handle_packet(Packet1, PacketTime1, self()),
        {ok, Packet1, PacketTime1}
    end,

    ok = pp_config:load_config([
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_dedupe_timeout">> => 0
        }
    ]),

    {ok, SCPacket1, GatewayTime1} = SendPacketFun(PubKeyBin1, ?DEVADDR_ACTILITY, -25.0),
    {ok, SCPacket2, _GatewayTime2} = SendPacketFun(PubKeyBin2, ?DEVADDR_ACTILITY, -30.0),
    Packet1 = blockchain_state_channel_packet_v1:packet(SCPacket1),
    Packet2 = blockchain_state_channel_packet_v1:packet(SCPacket2),
    Region = blockchain_state_channel_packet_v1:region(SCPacket1),

    MakeBaseExpect = fun(GatewayInfo) ->
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => pp_utils:binary_to_hexstring(
                blockchain_helium_packet_v1:payload(Packet1)
            ),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => pp_lorawan:datarate_to_index(
                    Region,
                    blockchain_helium_packet_v1:datarate(Packet1)
                ),
                <<"ULFreq">> => blockchain_helium_packet_v1:frequency(Packet1),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => pp_utils:format_time(GatewayTime1),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [GatewayInfo]
            }
        }
    end,

    {ok, _Data1, _, {200, _RespBody1}} = pp_lns:http_rcv(
        MakeBaseExpect(#{
            <<"ID">> => pp_utils:binary_to_hexstring(pp_utils:pubkeybin_to_mac(PubKeyBin1)),
            <<"RFRegion">> => erlang:atom_to_binary(Region),
            <<"RSSI">> => erlang:trunc(
                blockchain_helium_packet_v1:signal_strength(Packet1)
            ),
            <<"SNR">> => blockchain_helium_packet_v1:snr(Packet1),
            <<"DLAllowed">> => true
        })
    ),

    {ok, _Data2, _, {200, _RespBody2}} = pp_lns:http_rcv(
        MakeBaseExpect(#{
            <<"ID">> => pp_utils:binary_to_hexstring(pp_utils:pubkeybin_to_mac(PubKeyBin2)),
            <<"RFRegion">> => erlang:atom_to_binary(Region),
            <<"RSSI">> => erlang:trunc(
                blockchain_helium_packet_v1:signal_strength(Packet2)
            ),
            <<"SNR">> => blockchain_helium_packet_v1:snr(Packet2),
            <<"DLAllowed">> => true
        })
    ),

    ok.

join_net_id_offer_test(_Config) ->
    SendJoinOfferFun = fun(DevEUI, AppEUI) ->
        DevNonce = crypto:strong_rand_bytes(2),
        AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Offer = test_utils:join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI),
        pp_sc_packet_handler:handle_offer(Offer, self())
    end,

    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    DevEUI2 = <<0, 0, 0, 0, 0, 0, 0, 2>>,
    AppEUI2 = <<0, 0, 0, 2, 0, 0, 0, 2>>,

    %% Empty mapping, no joins
    ok = pp_config:load_config([]),
    ?assertMatch({error, unmapped_eui}, SendJoinOfferFun(DevEUI1, AppEUI1)),
    ?assertMatch({error, unmapped_eui}, SendJoinOfferFun(DevEUI2, AppEUI2)),

    %% Accept 1 Pair
    OneMapped = [
        #{
            <<"name">> => "two",
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI2, <<"app_eui">> => AppEUI2}
            ]
        }
    ],
    ok = pp_config:load_config(OneMapped),
    ?assertMatch({error, unmapped_eui}, SendJoinOfferFun(DevEUI1, AppEUI1)),
    ?assertMatch(ok, SendJoinOfferFun(DevEUI2, AppEUI2)),

    %% Accept Both
    TwoMapped = [
        #{
            <<"name">> => "one",
            <<"net_id">> => 1,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        },
        #{
            <<"name">> => "two",
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI2, <<"app_eui">> => AppEUI2}
            ]
        }
    ],
    ok = pp_config:load_config(TwoMapped),
    ?assertMatch(ok, SendJoinOfferFun(DevEUI1, AppEUI1)),
    ?assertMatch(ok, SendJoinOfferFun(DevEUI2, AppEUI2)),

    %% Accept One with multiple NetIDS
    OneMappedTwice = [
        #{
            <<"name">> => "one-1",
            <<"net_id">> => 1,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1},
                #{<<"dev_eui">> => DevEUI2, <<"app_eui">> => AppEUI2}
            ]
        },
        #{
            <<"name">> => "one-2",
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1},
                #{<<"dev_eui">> => DevEUI2, <<"app_eui">> => AppEUI2}
            ]
        }
    ],
    ok = pp_config:load_config(OneMappedTwice),
    ?assertMatch(ok, SendJoinOfferFun(DevEUI1, AppEUI1)),
    ?assertMatch(ok, SendJoinOfferFun(DevEUI2, AppEUI2)),

    ok.

join_net_id_packet_test(_Config) ->
    DevAddr = ?DEVADDR_COMCAST,
    NetID = ?NET_ID_COMCAST,
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    DevEUI2 = <<0, 0, 0, 0, 0, 0, 0, 2>>,
    AppEUI2 = <<0, 0, 0, 2, 0, 0, 0, 2>>,

    ok = pp_config:load_config([
        %% TODO: Make order not matter for this test.
        %% When joining, we go with the first #eui{}
        %% returned, which will be the second provided
        %% in the config list.
        #{
            <<"name">> => "test-2",
            <<"net_id">> => ?NET_ID_COMCAST_2,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        },
        #{
            <<"name">> => "test-1",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    %% ------------------------------------------------------------
    %% Send packet with Mapped EUI
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin1, DevAddr, 0, Routing, #{
        dont_encode => true
    }),

    {error, not_found} = pp_udp_sup:lookup_worker({PubKeyBin1, NetID}),
    pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),
    {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin1, NetID}),

    AddressPort = pp_udp_worker:get_address_and_port(Pid),
    ?assertEqual({"3.3.3.3", 3333}, AddressPort),

    %% ------------------------------------------------------------
    %% Send packet with unmapped EUI from a different gateway
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    Routing2 = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI2, AppEUI2}),

    Packet2 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin2,
        DevAddr,
        0,
        Routing2,
        #{dont_encode => true}
    ),

    {error, not_found} = pp_udp_sup:lookup_worker({PubKeyBin2, NetID}),
    pp_sc_packet_handler:handle_packet(Packet2, erlang:system_time(millisecond), self()),
    {error, not_found} = pp_udp_sup:lookup_worker({PubKeyBin2, NetID}),

    ok.

multi_buy_join_test(_Config) ->
    DevEUI = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    MakeJoinOffer = fun() ->
        DevNonce = crypto:strong_rand_bytes(2),
        AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        test_utils:join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI)
    end,

    application:set_env(packet_purchaser, join_net_ids, #{
        {DevEUI, AppEUI} => ?NET_ID_COMCAST
    }),

    %% -------------------------------------------------------------------
    %% Send more than one of the same join, only 1 should be bought
    BaseConfig = #{
        <<"name">> => "two",
        <<"net_id">> => ?NET_ID_COMCAST,
        <<"address">> => <<"3.3.3.3">>,
        <<"port">> => 3333,
        <<"multi_buy">> => 1,
        <<"joins">> => [
            #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
        ]
    },

    ok = pp_config:load_config([BaseConfig]),
    Offer1 = MakeJoinOffer(),

    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer1, self())),

    %% -------------------------------------------------------------------
    %% Send more than one of the same join, 2 should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 2})]),
    Offer2 = MakeJoinOffer(),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer2, self())),

    %% -------------------------------------------------------------------
    %% Send more than one of the same join, none should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 0})]),
    Offer3 = MakeJoinOffer(),
    ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),
    ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),
    ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),

    %% -------------------------------------------------------------------
    %% Send more than one of the same join, unlimited should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => <<"unlimited">>})]),
    Offer4 = MakeJoinOffer(),
    lists:foreach(
        fun(_Idx) ->
            ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer4, self()))
        end,
        lists:seq(1, 100)
    ),

    ok.

udp_change_location_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    SendPacketFun = fun(DevAddr, NetID) ->
        Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{
            dont_encode => true
        }),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin, NetID}),
        pp_udp_worker:get_address_and_port(Pid)
    end,

    %% Load a config,
    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"multi_buy">> => 1,
            <<"joins">> => []
        }
    ]),
    %% grab the worker and make sure it's pointed in the right direction
    ?assertMatch({"3.3.3.3", 3333}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST)),
    ?assertMatch({"3.3.3.3", 3333}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST)),

    %% Reload the config, different dest
    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"4.4.4.4">>,
            <<"port">> => 4444,
            <<"multi_buy">> => 1,
            <<"joins">> => []
        }
    ]),
    %% grab the worker and make sure it's pointed in the right direction
    ?assertMatch({"4.4.4.4", 4444}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST)),

    ok.

multi_buy_eviction_test(_Config) ->
    DevEUI = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    DevNonce = crypto:strong_rand_bytes(2),
    AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    JoinOffer = test_utils:join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI),
    PacketOffer = test_utils:packet_offer(PubKeyBin, ?DEVADDR_COMCAST),
    Timeout = 50,

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"multi_buy">> => 1,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
            ]
        }
    ]),

    ErrMaxPacket = {error, multi_buy_max_packet},
    lists:foreach(
        fun(Offer) ->
            %% -------------------------------------------------------------------
            %% Send more than one of the same offer, only 1 should be bought
            ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer, self())),
            ?assertMatch(ErrMaxPacket, pp_sc_packet_handler:handle_offer(Offer, self())),
            ?assertMatch(ErrMaxPacket, pp_sc_packet_handler:handle_offer(Offer, self())),

            %% Wait out the eviction, we're attempting a replay
            timer:sleep(round(Timeout * 1.3)),
            %% MB does bulk cleanup on large intervals, manually trigger
            ok = pp_multi_buy:cleanup(Timeout),
            ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer, self())),
            ?assertMatch(ErrMaxPacket, pp_sc_packet_handler:handle_offer(Offer, self())),
            ?assertMatch(ErrMaxPacket, pp_sc_packet_handler:handle_offer(Offer, self()))
        end,
        [JoinOffer, PacketOffer]
    ),

    ok.

config_inactive_test(_Config) ->
    MakePacketOffer = fun() ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        test_utils:packet_offer(PubKeyBin, ?DEVADDR_COMCAST)
    end,

    %% -------------------------------------------------------------------
    %% Send more than one of the same join to inactive partner, none should be bought
    BaseConfig = #{
        <<"name">> => "test",
        <<"net_id">> => ?NET_ID_COMCAST,
        <<"address">> => <<"3.3.3.3">>,
        <<"port">> => 3333,
        <<"multi_buy">> => 1,
        <<"active">> => false
    },
    ok = pp_config:load_config([BaseConfig]),
    Offer1 = MakePacketOffer(),
    ?assertMatch(
        {error, {buying_inactive, ?NET_ID_COMCAST}},
        pp_sc_packet_handler:handle_offer(Offer1, self())
    ),
    ?assertMatch(
        {error, {buying_inactive, ?NET_ID_COMCAST}},
        pp_sc_packet_handler:handle_offer(Offer1, self())
    ),
    ?assertMatch(
        {error, {buying_inactive, ?NET_ID_COMCAST}},
        pp_sc_packet_handler:handle_offer(Offer1, self())
    ),

    ok.

multi_buy_packet_test(_Config) ->
    MakePacketOffer = fun() ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        test_utils:packet_offer(PubKeyBin, ?DEVADDR_COMCAST)
    end,

    %% -------------------------------------------------------------------
    %% Send more than one of the same join packet, only 1 should be bought
    BaseConfig = #{
        <<"name">> => "test",
        <<"net_id">> => ?NET_ID_COMCAST,
        <<"address">> => <<"3.3.3.3">>,
        <<"port">> => 3333,
        <<"multi_buy">> => 1
    },
    ok = pp_config:load_config([BaseConfig]),
    Offer1 = MakePacketOffer(),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer1, self())),

    %% -------------------------------------------------------------------
    %% Send more than one of the same packet, 2 should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 2})]),
    Offer2 = MakePacketOffer(),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer2, self())),

    %% -------------------------------------------------------------------
    %% Send more than one of the same packet, none should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 0})]),
    Offer3 = MakePacketOffer(),
    ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),
    ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),
    ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),

    %% -------------------------------------------------------------------
    %% Send more than one of the same packet, unlimited should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => <<"unlimited">>})]),
    Offer4 = MakePacketOffer(),

    lists:foreach(
        fun(_Idx) ->
            ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer4, self()))
        end,
        lists:seq(1, 100)
    ),

    ok.

net_ids_map_offer_test(_Config) ->
    SendPacketOfferFun = fun(DevAddr) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Offer = test_utils:packet_offer(PubKeyBin, DevAddr),
        pp_sc_packet_handler:handle_offer(Offer, self())
    end,

    %% Reject all NetIDs
    ok = pp_config:load_config([]),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_ACTILITY)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_TEKTELIC)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_COMCAST)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_EXPERIMENTAL)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_ORANGE)),

    %% Buy Only Actility1 ID
    BaseConfig = #{
        <<"name">> => "test",
        <<"net_id">> => unset,
        <<"address">> => <<>>,
        <<"port">> => 1337
    },
    ActilityConfig = maps:merge(BaseConfig, #{<<"net_id">> => ?NET_ID_ACTILITY}),
    OrangeConfig = maps:merge(BaseConfig, #{<<"net_id">> => ?NET_ID_ORANGE}),
    TektelicConfig = maps:merge(BaseConfig, #{<<"net_id">> => ?NET_ID_TEKTELIC}),
    ExperimentalConfig = maps:merge(BaseConfig, #{<<"net_id">> => ?NET_ID_EXPERIMENTAL}),
    ComcastConfig = maps:merge(BaseConfig, #{<<"net_id">> => ?NET_ID_COMCAST}),

    ok = pp_config:load_config([ActilityConfig]),
    ?assertMatch(ok, SendPacketOfferFun(?DEVADDR_ACTILITY)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_TEKTELIC)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_COMCAST)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_EXPERIMENTAL)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_ORANGE)),

    %% Buy Multiple IDs
    ok = pp_config:load_config([ActilityConfig, OrangeConfig]),
    ?assertMatch(ok, SendPacketOfferFun(?DEVADDR_ACTILITY)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_TEKTELIC)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_COMCAST)),
    ?assertMatch({error, routing_not_found}, SendPacketOfferFun(?DEVADDR_EXPERIMENTAL)),
    ?assertMatch(ok, SendPacketOfferFun(?DEVADDR_ORANGE)),

    %% Buy all the IDs we know about
    ok = pp_config:load_config([
        ExperimentalConfig,
        ActilityConfig,
        TektelicConfig,
        OrangeConfig,
        ComcastConfig
    ]),
    ?assertMatch(ok, SendPacketOfferFun(?DEVADDR_ACTILITY)),
    ?assertMatch(ok, SendPacketOfferFun(?DEVADDR_TEKTELIC)),
    ?assertMatch(ok, SendPacketOfferFun(?DEVADDR_COMCAST)),
    ?assertMatch(ok, SendPacketOfferFun(?DEVADDR_EXPERIMENTAL)),
    ?assertMatch(ok, SendPacketOfferFun(?DEVADDR_ORANGE)),

    ok.

udp_multiple_joins_test(_Config) ->
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, ?DEVADDR_COMCAST, 0, Routing, #{
        dont_encode => true
    }),

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"udp">>,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => 1111,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"protocol">> => <<"udp">>,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => 2222,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    {ok, OnePid} = pp_lns:start_link(#{port => 1111, forward => self()}),
    {ok, TwoPid} = pp_lns:start_link(#{port => 2222, forward => self()}),

    ok = pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

    PushData = 0,
    {ok, _} = pp_lns:rcv(OnePid, PushData),
    {ok, _} = pp_lns:rcv(TwoPid, PushData),

    ok.

udp_multiple_joins_same_dest_test(_Config) ->
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, ?DEVADDR_COMCAST, 0, Routing, #{
        dont_encode => true
    }),

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"udp">>,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => 1111,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"protocol">> => <<"udp">>,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => 1111,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    {ok, OnePid} = pp_lns:start_link(#{port => 1111, forward => self()}),

    ok = pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

    PushData = 0,
    {ok, _} = pp_lns:rcv(OnePid, PushData),
    ok = pp_lns:not_rcv(OnePid, PushData, timer:seconds(1)),

    ok.

packet_websocket_test(_Config) ->
    %% make sure the websocket comes up
    {ok, _WSPid} = test_utils:ws_init(),

    SendPacketFun = fun(DevAddr, NetID) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{
            dont_encode => true
        }),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin, NetID}),
        pp_udp_worker:get_address_and_port(Pid)
    end,

    %% ok = pp_console_dc_tracker:refill(?NET_ID_ACTILITY, 1, 100),
    %% ok = pp_console_dc_tracker:refill(?NET_ID_ORANGE, 1, 100),
    %% ok = pp_console_dc_tracker:refill(?NET_ID_COMCAST, 1, 100),

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"address">> => <<"1.1.1.1">>,
            <<"port">> => 1111
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"address">> => <<"2.2.2.2">>,
            <<"port">> => 2222
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333
        }
    ]),

    ?assertMatch({"1.1.1.1", 1111}, SendPacketFun(?DEVADDR_ACTILITY, ?NET_ID_ACTILITY)),
    ?assertMatch({"2.2.2.2", 2222}, SendPacketFun(?DEVADDR_ORANGE, ?NET_ID_ORANGE)),
    ?assertMatch({"3.3.3.3", 3333}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST)),

    ?assertMatch(
        {ok, #{
            <<"net_id">> := ?NET_ID_ACTILITY,
            <<"packet_hash">> := _,
            <<"packet_size">> := _,
            <<"reported_at_epoch">> := Time0,
            <<"type">> := <<"packet">>
        }} when erlang:is_integer(Time0),
        test_utils:ws_rcv()
    ),
    ?assertMatch(
        {ok, #{
            <<"net_id">> := ?NET_ID_ORANGE,
            <<"packet_hash">> := _,
            <<"packet_size">> := _,
            <<"reported_at_epoch">> := Time1,
            <<"type">> := <<"packet">>
        }} when erlang:is_integer(Time1),
        test_utils:ws_rcv()
    ),
    ?assertMatch(
        {ok, #{
            <<"net_id">> := ?NET_ID_COMCAST,
            <<"packet_hash">> := _,
            <<"packet_size">> := _,
            <<"reported_at_epoch">> := Time2,
            <<"type">> := <<"packet">>
        }} when erlang:is_integer(Time2),
        test_utils:ws_rcv()
    ),

    ok.

packet_websocket_inactive_test(_Config) ->
    %% make sure the does not websocket comes up
    ?assertException(exit, {test_case_failed, websocket_init_timeout}, test_utils:ws_init()),

    SendPacketFun = fun(DevAddr, NetID) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{
            dont_encode => true
        }),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin, NetID}),
        pp_udp_worker:get_address_and_port(Pid)
    end,

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"address">> => <<"1.1.1.1">>,
            <<"port">> => 1111
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"address">> => <<"2.2.2.2">>,
            <<"port">> => 2222
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333
        }
    ]),

    ?assertMatch({"1.1.1.1", 1111}, SendPacketFun(?DEVADDR_ACTILITY, ?NET_ID_ACTILITY)),
    ?assertMatch({"2.2.2.2", 2222}, SendPacketFun(?DEVADDR_ORANGE, ?NET_ID_ORANGE)),
    ?assertMatch({"3.3.3.3", 3333}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST)),

    ?assertException(exit, {test_case_failed, websocket_msg_timeout}, test_utils:ws_rcv()),
    ?assertException(exit, {test_case_failed, websocket_msg_timeout}, test_utils:ws_rcv()),
    ?assertException(exit, {test_case_failed, websocket_msg_timeout}, test_utils:ws_rcv()),

    ok.

join_websocket_test(_Config) ->
    DevAddr = ?DEVADDR_COMCAST,
    NetID = ?NET_ID_COMCAST,
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    DevEUI2 = <<0, 0, 0, 0, 0, 0, 0, 2>>,
    AppEUI2 = <<0, 0, 0, 2, 0, 0, 0, 2>>,

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    %% ------------------------------------------------------------
    %% Send packet with Mapped EUI
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin1, DevAddr, 0, Routing, #{
        dont_encode => true
    }),

    %% make sure websocket has started and eat address message
    {ok, _} = test_utils:ws_init(),

    pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),
    ?assertMatch(
        {ok, #{
            <<"net_id">> := NetID,
            <<"packet_hash">> := _,
            <<"packet_size">> := _,
            <<"reported_at_epoch">> := Time0,
            <<"type">> := <<"join">>
        }} when erlang:is_integer(Time0),
        test_utils:ws_rcv()
    ),

    %% ------------------------------------------------------------
    %% Send packet with unmapped EUI from a different gateway
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    Routing2 = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI2, AppEUI2}),

    Packet2 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin2,
        DevAddr,
        0,
        Routing2,
        #{dont_encode => true}
    ),

    pp_sc_packet_handler:handle_packet(Packet2, erlang:system_time(millisecond), self()),
    ?assertException(
        exit,
        {test_case_failed, websocket_msg_timeout},
        test_utils:ws_rcv()
    ),

    ok.

stop_start_purchasing_net_id_packet_test(_Config) ->
    MakePacketOffer = fun(DevAddr) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        test_utils:packet_offer(PubKeyBin, DevAddr)
    end,

    Config = [
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333
        },
        #{
            <<"name">> => "test_stable",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"address">> => <<"4.4.4.4">>,
            <<"port">> => 4444
        }
    ],
    ok = pp_config:load_config(Config),
    Offer1 = MakePacketOffer(?DEVADDR_COMCAST),
    Offer2 = MakePacketOffer(?DEVADDR_ORANGE),

    %% -------------------------------------------------------------------
    %% Default we should buy all packets in config
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),

    %% -------------------------------------------------------------------
    %% Stop buying
    ok = pp_config:stop_buying([?NET_ID_COMCAST]),
    ?assertMatch(
        {error, {buying_inactive, ?NET_ID_COMCAST}},
        pp_sc_packet_handler:handle_offer(Offer1, self())
    ),
    %% Offer from different NetID should still be purchased
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),

    %% -------------------------------------------------------------------
    %% Start buying again
    ok = pp_config:start_buying([?NET_ID_COMCAST]),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),

    ok.

stop_start_purchasing_net_id_join_test(_Config) ->
    MakeJoinOffer = fun(DevEUI, AppEUI) ->
        DevNonce = crypto:strong_rand_bytes(2),
        AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        test_utils:join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI)
    end,

    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,
    DevEUI2 = <<0, 0, 0, 0, 0, 0, 0, 2>>,
    AppEUI2 = <<0, 0, 0, 2, 0, 0, 0, 2>>,
    DevEUI3 = <<0, 0, 0, 0, 0, 0, 0, 3>>,
    AppEUI3 = <<0, 0, 0, 2, 0, 0, 0, 3>>,
    Config = [
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1},
                #{<<"dev_eui">> => DevEUI2, <<"app_eui">> => AppEUI2}
            ]
        },
        #{
            <<"name">> => "test_stable",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"address">> => <<"4.4.4.4">>,
            <<"port">> => 4444,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI3, <<"app_eui">> => AppEUI3}
            ]
        }
    ],
    ok = pp_config:load_config(Config),
    Dev1Offer = MakeJoinOffer(DevEUI1, AppEUI1),
    Dev2Offer = MakeJoinOffer(DevEUI2, AppEUI2),
    Dev3Offer = MakeJoinOffer(DevEUI3, AppEUI3),

    %% -------------------------------------------------------------------
    %% Default we should buy all Joins in configs
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Dev1Offer, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Dev2Offer, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Dev3Offer, self())),

    %% -------------------------------------------------------------------
    %% Stop buying
    ok = pp_config:stop_buying([?NET_ID_COMCAST]),
    ?assertMatch(
        {error, {buying_inactive, ?NET_ID_COMCAST}},
        pp_sc_packet_handler:handle_offer(Dev1Offer, self())
    ),
    ?assertMatch(
        {error, {buying_inactive, ?NET_ID_COMCAST}},
        pp_sc_packet_handler:handle_offer(Dev2Offer, self())
    ),
    %% Offer from different NetID should still be purchased
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Dev3Offer, self())),

    %% -------------------------------------------------------------------
    %% Start buying again
    ok = pp_config:start_buying([?NET_ID_COMCAST]),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Dev1Offer, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Dev2Offer, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Dev3Offer, self())),

    ok.

join_websocket_inactive_test(_Config) ->
    DevAddr = ?DEVADDR_COMCAST,
    NetID = ?NET_ID_COMCAST,
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    DevEUI2 = <<0, 0, 0, 0, 0, 0, 0, 2>>,
    AppEUI2 = <<0, 0, 0, 2, 0, 0, 0, 2>>,

    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => NetID,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"joins">> => [
                #{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}
            ]
        }
    ]),

    %% ------------------------------------------------------------
    %% Send packet with Mapped EUI
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin1, DevAddr, 0, Routing, #{
        dont_encode => true
    }),

    %% make sure the does not websocket comes up
    ?assertException(exit, {test_case_failed, websocket_init_timeout}, test_utils:ws_init()),

    pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),
    ?assertException(exit, {test_case_failed, websocket_msg_timeout}, test_utils:ws_rcv()),

    %% ------------------------------------------------------------
    %% Send packet with unmapped EUI from a different gateway
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    Routing2 = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI2, AppEUI2}),

    Packet2 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin2,
        DevAddr,
        0,
        Routing2,
        #{dont_encode => true}
    ),

    pp_sc_packet_handler:handle_packet(Packet2, erlang:system_time(millisecond), self()),
    ?assertException(
        exit,
        {test_case_failed, websocket_msg_timeout},
        test_utils:ws_rcv()
    ),

    ok.

net_ids_map_packet_test(_Config) ->
    SendPacketFun = fun(DevAddr, NetID) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{
            dont_encode => true
        }),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin, NetID}),
        pp_udp_worker:get_address_and_port(Pid)
    end,
    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"address">> => <<"1.1.1.1">>,
            <<"port">> => 1111
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"address">> => <<"2.2.2.2">>,
            <<"port">> => 2222
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333
        }
    ]),
    ?assertMatch({"1.1.1.1", 1111}, SendPacketFun(?DEVADDR_ACTILITY, ?NET_ID_ACTILITY)),
    ?assertMatch({"2.2.2.2", 2222}, SendPacketFun(?DEVADDR_ORANGE, ?NET_ID_ORANGE)),
    ?assertMatch({"3.3.3.3", 3333}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST)),
    ok.

net_ids_no_config_test(_Config) ->
    SendPacketFun = fun(DevAddr, NetID) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{
            dont_encode => true
        }),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        pp_udp_sup:lookup_worker({PubKeyBin, NetID})
    end,
    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"address">> => <<"1.1.1.1">>,
            <<"port">> => 1111
        }
    ]),
    ?assertMatch({ok, _}, SendPacketFun(?DEVADDR_ACTILITY, ?NET_ID_ACTILITY)),
    ?assertMatch({error, not_found}, SendPacketFun(?DEVADDR_ORANGE, ?NET_ID_ORANGE)),
    ?assertMatch({error, not_found}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST)),

    ok.

single_hotspot_multi_net_id_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    SendPacketFun = fun(DevAddr, NetID) ->
        Packet = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{
            dont_encode => true
        }),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin, NetID}),
        pp_udp_worker:get_address_and_port(Pid)
    end,
    ok = pp_config:load_config([
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"address">> => <<"1.1.1.1">>,
            <<"port">> => 1111
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_ORANGE,
            <<"address">> => <<"2.2.2.2">>,
            <<"port">> => 2222
        },
        #{
            <<"name">> => "test",
            <<"net_id">> => ?NET_ID_COMCAST,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333
        }
    ]),
    ?assertMatch({"1.1.1.1", 1111}, SendPacketFun(?DEVADDR_ACTILITY, ?NET_ID_ACTILITY)),
    ?assertMatch({"2.2.2.2", 2222}, SendPacketFun(?DEVADDR_ORANGE, ?NET_ID_ORANGE)),
    ?assertMatch({"3.3.3.3", 3333}, SendPacketFun(?DEVADDR_COMCAST, ?NET_ID_COMCAST)),
    ok.

multiple_protocol_single_gateway_downlink_test(_Config) ->
    %% If a packet get's sent to a UDP _and_ HTTP roamer from the same gateway,
    %% then a UDP response is sent through that gateway, regardless of if it was
    %% meant for the latest packet, the downlink will use one of the PIDs the
    %% future HTTP packet is trying to use.
    %%
    %% This test ensures that HTTP downlinks are not tied to a specific PID, and
    %% can get any available PID from the gateway.
    %%
    %% Could happen with any packets that go through a UDP gateway.
    %% Device-1 uplinks udp.
    %% Device-2 uplinks through same gateway, udp and http.
    %% Device-1 downlinks.
    %% Device-2 http downlink fails.

    %%
    %% Forwarder : packet-purchaser
    %% Roamer    : partner-lns
    %%
    ok = start_forwarder_listener(),
    %% Add a small delay for http downlink so we can ensure the udp downlink goes first.
    ok = start_roamer_listener(#{callback_args => #{wait_ms => 500}}),
    {ok, UDPPid} = pp_lns:start_link(#{port => 1111, forward => self()}),

    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    %% 1) Get a gateway to send from
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% RSSI and FCnt don't matter here, they're made different to help with debugging
    Routing = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI1, AppEUI1}),
    JoinPacket = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin,
        ?DEVADDR_ACTILITY,
        0,
        Routing,
        #{dont_encode => true, rssi => -120}
    ),
    DataPacket = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin,
        ?DEVADDR_ACTILITY,
        42,
        #{dont_encode => true, rssi => -42}
    ),

    %% 2) Load config
    %%  - UDP that accepts joins and devaddrs
    %%  - HTTP that accepts joins
    ok = pp_config:load_config([
        #{
            <<"name">> => <<"udp_test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"udp">>,
            <<"address">> => <<"127.0.0.1">>,
            <<"port">> => 1111,
            <<"joins">> => [#{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}],
            <<"devaddrs">> => [
                #{<<"lower">> => ?DEVADDR_ACTILITY_BIN, <<"upper">> => ?DEVADDR_ACTILITY_BIN}
            ]
        },
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => ?NET_ID_ACTILITY,
            <<"protocol">> => <<"http">>,
            <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
            <<"http_flow_type">> => <<"async">>,
            <<"joins">> => [#{<<"dev_eui">> => DevEUI1, <<"app_eui">> => AppEUI1}]
        }
    ]),
    %% Spin up 2 procs to act as gateways that whose connections will go down
    %% when they receive a downlink. Otherwise the test will never fail, as the
    %% test Pid lives throughout the test.
    TestPid = self(),
    JoinPacketReceiver = spawn(fun() ->
        receive
            Msg ->
                %% ct:print("ONE (join_packet) received: ~p", [Msg]),
                TestPid ! Msg
        after timer:seconds(2) -> TestPid ! nothing_received
        end
    end),
    DataPacketReceiver = spawn(fun() ->
        receive
            Msg ->
                %% ct:print("TWO (data_packet) received: ~p", [Msg]),
                TestPid ! Msg
        after timer:seconds(2) -> TestPid ! nothing_received
        end
    end),

    %% 3) Send join and data packet
    ok = pp_sc_packet_handler:handle_packet(
        DataPacket,
        erlang:system_time(millisecond),
        DataPacketReceiver
    ),
    timer:sleep(50),
    ok = pp_sc_packet_handler:handle_packet(
        JoinPacket,
        erlang:system_time(millisecond),
        JoinPacketReceiver
    ),

    %% Collect the UDP packets
    PushData = 0,
    {ok, _UDPJoinRequest} = pp_lns:rcv(UDPPid, PushData),
    {ok, _UDPDataRequest} = pp_lns:rcv(UDPPid, PushData),

    %% 4) UDP downlink to devaddr
    {ok, GatewayPid} = pp_udp_sup:lookup_worker({PubKeyBin, ?NET_ID_ACTILITY}),
    Port = pp_udp_worker:get_port(GatewayPid),

    Token = semtech_udp:token(),
    ok = pp_lns:pull_resp(UDPPid, "127.0.0.1", Port, Token, #{
        data => <<"downlink_payload">>,
        tmst => erlang:system_time(millisecond),
        freq => 915.0,
        datr => <<"SF11BW125">>,
        powe => 27
    }),
    TxAck = 5,
    ?assertMatch({ok, {Token, _, _}}, pp_lns:rcv(UDPPid, TxAck)),
    % Downlink received by hotspot
    ok = gateway_expect_downlink(fun(SCResp) ->
        Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
        ?assertEqual(<<"downlink_payload">>, blockchain_helium_packet_v1:payload(Downlink)),
        ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
        ok
    end),

    %% 5) HTTP join_request
    {ok, _HttpJoinRequest} = roamer_expect_uplink_data(),
    %% Expect join_accept
    {ok, _Data} = forwarder_expect_downlink_data(),

    %% 5.1) device should join_accept
    ok = gateway_expect_downlink(fun(SCResp) ->
        Downlink = blockchain_state_channel_response_v1:downlink(SCResp),
        ?assertEqual(<<"join_accept_payload">>, blockchain_helium_packet_v1:payload(Downlink)),
        ?assertEqual(27, blockchain_helium_packet_v1:signal_strength(Downlink)),
        ok
    end),

    %% Ensure both Pids were used for downlinking
    ok =
        receive
            nothing_received -> ct:fail("Both gateway stand-in pids should have been used and gone")
        after 250 -> ok
        end,

    ok.

multi_buy_worst_case_stress_test(_Config) ->
    <<DevNum:32/integer-unsigned>> = ?DEVADDR_COMCAST,

    MakeOfferFun = fun(Payload) ->
        fun(PubKeyBin, SigFun) ->
            Packet = blockchain_helium_packet_v1:new(
                lorawan,
                Payload,
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
        end
    end,

    RunCycle = fun(#{actors := NumActors, packets := NumPackets, multi_buy := MultiBuy}) ->
        Actors = lists:map(
            fun(_I) ->
                #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
                PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
                SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
                #{
                    pubkeybin => PubKeyBin,
                    sig_fun => SigFun,
                    public => PubKey,
                    secret => PrivKey,
                    wait_time => rand:uniform(200)
                }
            end,
            lists:seq(1, NumActors + 1)
        ),

        ok = pp_config:load_config([
            #{
                <<"name">> => "test",
                <<"net_id">> => ?NET_ID_COMCAST,
                <<"address">> => <<"1.1.1.1">>,
                <<"port">> => 1111,
                <<"multi_buy">> => MultiBuy
            }
        ]),

        Start = erlang:system_time(millisecond),
        lists:foreach(
            fun(_I) ->
                Payload = crypto:strong_rand_bytes(20),
                ok = send_same_offer_with_actors(Actors, MakeOfferFun(Payload), self())
            end,
            lists:seq(1, NumPackets + 1)
        ),
        Times = all_dead(NumActors * NumPackets, NumActors * NumPackets, []),

        End = erlang:system_time(millisecond),
        Mills = End - Start,
        TotalSeconds = erlang:convert_time_unit(Mills, millisecond, second),
        Average = lists:sum(Times) / length(Times),
        Min = lists:min(Times),
        Max = lists:max(Times),

        {Hour, Minute, Second} = calendar:seconds_to_time(TotalSeconds),
        ct:print(
            "NumPackets: ~p~n"
            "Actors: ~p~n"
            "MultiBuy: ~p~n"
            "Time: ~ph ~pm ~ps ~pms~n"
            "Average: ~pms Max: ~pms Min: ~pms~n",
            %% "ETS Info: ~p",
            [
                NumPackets,
                NumActors,
                MultiBuy,
                Hour,
                Minute,
                Second,
                (Mills - (Second * 1000)),
                round(Average),
                Max,
                Min
                %% ets:info(multi_buy_ets)
            ]
        ),
        {Average, Max}
    end,

    %% First run is to eat some time costs
    RunCycle(#{actors => 10, packets => 10, multi_buy => 1}),
    %% NOTE: Limits in ms. This test is a heuristic to let us know if we've
    %% added something that slows down the offer pipeline
    AvgLimit = 10,
    MaxLimit = 100,
    lists:foreach(
        fun(ArgMap) ->
            {Avg, Max} = RunCycle(ArgMap),
            ?assert(Avg < AvgLimit),
            ?assert(Max < MaxLimit)
        end,
        [
            #{actors => 30, packets => 500, multi_buy => 1},
            #{actors => 30, packets => 500, multi_buy => 5},
            #{actors => 30, packets => 500, multi_buy => 9999}
        ]
    ),

    ok.

all_dead(_Start, 0, Times) ->
    Times;
all_dead(Start, Num, Times) ->
    receive
        {done, Time} ->
            all_dead(Start, Num - 1, [Time | Times])
    after 5000 ->
        ct:fail("Something is not dying, waiting on ~p more from ~p... ~p have died", [
            Num,
            Start,
            Start - Num
        ])
    end.

send_same_offer_with_actors([], _MakeOfferFun, _DeadPid) ->
    ok;
send_same_offer_with_actors([A | Rest], MakeOfferFun, DeadPid) ->
    erlang:spawn_link(
        fun() ->
            #{wait_time := Wait, pubkeybin := PubKeyBin, sig_fun := SigFun} = A,
            timer:sleep(Wait),
            Start = erlang:monotonic_time(millisecond),
            _ = pp_sc_packet_handler:handle_offer(MakeOfferFun(PubKeyBin, SigFun), self()),
            End = erlang:monotonic_time(millisecond),
            DeadPid ! {done, End - Start}
        end
    ),
    send_same_offer_with_actors(Rest, MakeOfferFun, DeadPid).

start_uplink_listener() ->
    start_uplink_listener(#{callback_args => #{}}).

start_uplink_listener(Options) ->
    %% Uplinks we send to an LNS
    CallbackArgs = maps:get(callback_args, Options, #{}),
    {ok, _ElliPid} = elli:start_link([
        {callback, pp_lns},
        {callback_args, maps:merge(#{forward => self()}, CallbackArgs)},
        {port, maps:get(port, Options, 3002)},
        {min_acceptors, 1}
    ]),
    ok.

start_downlink_listener() ->
    {ok, _ElliPid} = elli:start_link([
        {callback, pp_lns},
        {callback_args, #{forward => self()}},
        {port, 3003},
        {min_acceptors, 1}
    ]),
    ok.

start_forwarder_listener() ->
    start_downlink_listener().

start_roamer_listener(Opts) ->
    start_uplink_listener(Opts).

start_roamer_listener() ->
    start_uplink_listener().

roamer_expect_uplink_data(Expected) ->
    {ok, Got} = roamer_expect_uplink_data(),
    case test_utils:match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({roamer_expect_uplink_data, Reason})
    end.

roamer_expect_uplink_data() ->
    receive
        http_uplink_data -> ct:fail({http_uplink_data_err, no_payload});
        {http_uplink_data, Payload} -> {ok, jsx:decode(Payload)}
    after 1000 -> ct:fail(http_uplink_data_timeout)
    end.

forwarder_expect_response(Code) ->
    receive
        {http_uplink_data_response, Code} ->
            ok;
        {http_uplink_data_response, OtherCode} ->
            ct:fail({http_uplink_data_response_err, [{expected, Code}, {got, OtherCode}]})
    after 1000 -> ct:fail(http_uplink_data_200_response_timeout)
    end.

forwarder_expect_downlink_data(Expected) ->
    {ok, Got} = forwarder_expect_downlink_data(),
    case test_utils:match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({forwarder_expect_downlink_data, Reason})
    end.

forwarder_expect_downlink_data() ->
    receive
        http_downlink_data -> ct:fail({http_downlink_data, no_payload});
        {http_downlink_data_error, Err} -> ct:fail(Err);
        {http_downlink_data, Payload} -> {ok, jsx:decode(Payload)}
    after 1000 -> ct:fail(http_downlink_data_timeout)
    end.

roamer_expect_response(Code) ->
    receive
        {http_downlink_data_response, Code} ->
            ok;
        {http_downlink_data_response, OtherCode} ->
            ct:fail({http_downlink_data_response_err, [{expected, Code}, {got, OtherCode}]})
    after 1000 -> ct:fail(http_downlink_data_200_response_timeout)
    end.

gateway_expect_downlink(ExpectFn) ->
    receive
        {send_response, SCResp} ->
            ct:print("gateway got response: ~p", [SCResp]),
            ExpectFn(SCResp)
    after 1000 -> ct:fail(gateway_expect_downlink_timeout)
    end.
