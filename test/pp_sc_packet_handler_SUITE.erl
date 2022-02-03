-module(pp_sc_packet_handler_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    join_net_id_offer_test/1,
    join_net_id_packet_test/1,
    net_ids_map_offer_test/1,
    net_ids_map_packet_test/1,
    net_ids_no_config_test/1,
    single_hotspot_multi_net_id_test/1,
    multi_buy_join_test/1,
    multi_buy_packet_test/1,
    multi_buy_eviction_test/1,
    multi_buy_worst_case_stress_test/1,
    packet_websocket_test/1,
    packet_websocket_inactive_test/1,
    join_websocket_test/1,
    join_websocket_inactive_test/1,
    stop_start_purchasing_net_id_packet_test/1,
    stop_start_purchasing_net_id_join_test/1
]).

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
        join_net_id_offer_test,
        join_net_id_packet_test,
        net_ids_map_offer_test,
        net_ids_map_packet_test,
        net_ids_no_config_test,
        single_hotspot_multi_net_id_test,
        multi_buy_join_test,
        multi_buy_packet_test,
        multi_buy_eviction_test,
        %%
        packet_websocket_test,
        packet_websocket_inactive_test,
        join_websocket_test,
        join_websocket_inactive_test,
        %% multi_buy_worst_case_stress_test
        stop_start_purchasing_net_id_packet_test,
        stop_start_purchasing_net_id_join_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(join_websocket_inactive_test = TestCase, Config0) ->
    Config1 = [
        {console_api, [{is_active, false}]}
        | Config0
    ],
    test_utils:init_per_testcase(TestCase, Config1);
init_per_testcase(packet_websocket_inactive_test = TestCase, Config0) ->
    Config1 = [
        {console_api, [{is_active, false}]}
        | Config0
    ],
    test_utils:init_per_testcase(TestCase, Config1);
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

    ok.

join_net_id_packet_test(_Config) ->
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

    {error, not_found} = pp_udp_sup:lookup_worker({PubKeyBin1, NetID}),
    pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),
    {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin1, NetID}),

    AddressPort = get_udp_worker_address_port(Pid),
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
    %% Send more than one of the same join packet, only 1 should be bought
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
    %% Send more than one of the same join packet, 2 should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 2})]),
    Offer2 = MakeJoinOffer(),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer2, self())),

    %% -------------------------------------------------------------------
    %% Send more than one of the same join packet, unlimited should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => <<"unlimited">>})]),
    Offer3 = MakeJoinOffer(),
    lists:foreach(
        fun(_Idx) ->
            ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer3, self()))
        end,
        lists:seq(1, 100)
    ),

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
    application:set_env(packet_purchaser, multi_buy_eviction_timeout, Timeout),

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
            ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer, self())),
            ?assertMatch(ErrMaxPacket, pp_sc_packet_handler:handle_offer(Offer, self())),
            ?assertMatch(ErrMaxPacket, pp_sc_packet_handler:handle_offer(Offer, self()))
        end,
        [JoinOffer, PacketOffer]
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
    %% Send more than one of the same join packet, 2 should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 2})]),
    Offer2 = MakePacketOffer(),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer2, self())),

    %% -------------------------------------------------------------------
    %% Send more than one of the same join packet, unlimited should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => <<"unlimited">>})]),
    Offer3 = MakePacketOffer(),

    lists:foreach(
        fun(_Idx) ->
            ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer3, self()))
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
        get_udp_worker_address_port(Pid)
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
        get_udp_worker_address_port(Pid)
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
        {error, buying_inactive, ?NET_ID_COMCAST},
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
        {error, buying_inactive, ?NET_ID_COMCAST},
        pp_sc_packet_handler:handle_offer(Dev1Offer, self())
    ),
    ?assertMatch(
        {error, buying_inactive, ?NET_ID_COMCAST},
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
        get_udp_worker_address_port(Pid)
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
        get_udp_worker_address_port(Pid)
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

get_udp_worker_address_port(Pid) ->
    {
        state,
        _Chain,
        _Loc,
        _PubKeyBin1,
        _NetID,
        Socket,
        _PushData,
        _ScPid,
        _PullData,
        _PullDataTimer,
        _ShutdownTimer
    } = sys:get_state(Pid),
    pp_udp_socket:get_address(Socket).
