-module(pp_grpc_SUITE).

-export([
    all/0,
    groups/0,
    init_per_testcase/2,
    end_per_testcase/2,
    init_per_group/2,
    end_per_group/2
]).

-export([
    grpc_join_net_id_packet_test/1,
    grpc_net_ids_map_packet_test/1,
    grpc_net_ids_no_config_test/1,
    grpc_single_hotspot_multi_net_id_test/1,
    grpc_multi_buy_join_test/1,
    grpc_multi_buy_packet_test/1
]).

-include_lib("eunit/include/eunit.hrl").

%% NetIDs
-define(NET_ID_ACTILITY, 16#000002).

-define(NET_ID_COMCAST, 16#000022).
-define(NET_ID_ORANGE, 16#00000F).

%% DevAddrs

% pp_utils:hex_to_binary(<<"04ABCDEF">>)
-define(DEVADDR_ACTILITY, <<4, 171, 205, 239>>).

% pp_utils:hex_to_binary(<<"45000042">>)
-define(DEVADDR_COMCAST, <<69, 0, 0, 66>>).
%pp_utils:hex_to_binary(<<"1E123456">>)
-define(DEVADDR_ORANGE, <<30, 18, 52, 86>>).

-define(NWK_SESSION_KEY,
    <<81, 103, 129, 150, 35, 76, 17, 164, 210, 66, 210, 149, 120, 193, 251, 85>>
).
-define(APP_SESSION_KEY,
    <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>
).

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
        grpc_join_net_id_packet_test,
        grpc_net_ids_map_packet_test,
        grpc_net_ids_no_config_test,
        grpc_single_hotspot_multi_net_id_test,
        grpc_multi_buy_join_test,
        grpc_multi_buy_packet_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
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

init_per_testcase(TestCase, Config) ->
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

grpc_join_net_id_packet_test(_Config) ->
    NetID = ?NET_ID_COMCAST,
    DevEUI1 = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI1 = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    DevEUI2 = <<0, 0, 0, 0, 0, 0, 0, 2>>,
    AppEUI2 = <<0, 0, 0, 2, 0, 0, 0, 2>>,

    ok = pp_config:load_config([
        #{
            <<"name">> => "test-2",
            <<"net_id">> => 16#600013,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"joins">> => [
                #{
                    <<"dev_eui">> => bin_to_int(DevEUI1),
                    <<"app_eui">> => bin_to_int(AppEUI1)
                }
            ]
        },
        #{
            <<"name">> => "test-1",
            <<"net_id">> => 16#000022,
            <<"address">> => <<"3.3.3.3">>,
            <<"port">> => 3333,
            <<"joins">> => [
                #{
                    <<"dev_eui">> => bin_to_int(DevEUI1),
                    <<"app_eui">> => bin_to_int(AppEUI1)
                }
            ]
        }
    ]),

    %% ------------------------------------------------------------
    %% Send packet with Mapped EUI
    #{public := PubKey1, secret := PrivKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    AppKey = crypto:strong_rand_bytes(16),
    JoinNonce = crypto:strong_rand_bytes(2),

    %% create a join packet
    EnvUp1 = test_utils:packet_router_join_env_up(
        AppKey,
        JoinNonce,
        DevEUI1,
        AppEUI1,
        PubKeyBin1,
        SigFun1
    ),

    {ok, Stream} = helium_packet_router_packet_client:route(),
    {error, not_found} = pp_udp_sup:lookup_worker({PubKeyBin1, NetID}),
    ok = grpcbox_client:send(Stream, EnvUp1),

    timer:sleep(1000),
    {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin1, NetID}),

    AddressPort = pp_udp_worker:get_address_and_port(Pid),
    ?assertEqual({"3.3.3.3", 3333}, AddressPort),

    %% ------------------------------------------------------------
    %% Send packet with unmapped EUI from a different gateway
    #{public := PubKey2, secret := PrivKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),
    %% create a join packet
    EnvUp2 = test_utils:packet_router_join_env_up(
        AppKey,
        JoinNonce,
        DevEUI2,
        AppEUI2,
        PubKeyBin2,
        SigFun2
    ),
    {error, not_found} = pp_udp_sup:lookup_worker({PubKeyBin2, NetID}),
    %% pp_sc_packet_handler:handle_packet(Packet2, erlang:system_time(millisecond), self()),
    ok = grpcbox_client:send(Stream, EnvUp2),
    {error, not_found} = pp_udp_sup:lookup_worker({PubKeyBin2, NetID}),
    ok.

grpc_net_ids_map_packet_test(_Config) ->
    {ok, Stream} = helium_packet_router_packet_client:route(),

    SendPacketFun = fun(DevAddr, NetID) ->
        #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        SigFun = libp2p_crypto:mk_sig_fun(PrivKey),

        EnvUp = test_utils:packet_router_data_env_up(
            DevAddr,
            ?NWK_SESSION_KEY,
            ?APP_SESSION_KEY,
            0,
            PubKeyBin,
            SigFun
        ),

        ok = grpcbox_client:send(Stream, EnvUp),
        timer:sleep(100),
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

grpc_net_ids_no_config_test(_Config) ->
    {ok, Stream} = helium_packet_router_packet_client:route(),

    SendPacketFun = fun(DevAddr, NetID) ->
        #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        SigFun = libp2p_crypto:mk_sig_fun(PrivKey),

        EnvUp = test_utils:packet_router_data_env_up(
            DevAddr,
            ?NWK_SESSION_KEY,
            ?APP_SESSION_KEY,
            0,
            PubKeyBin,
            SigFun
        ),
        ok = grpcbox_client:send(Stream, EnvUp),
        timer:sleep(100),

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

grpc_single_hotspot_multi_net_id_test(_Config) ->
    {ok, Stream} = helium_packet_router_packet_client:route(),

    %% One Gateway is going to be sending all the packets.
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),

    SendPacketFun = fun(DevAddr, NetID) ->
        EnvUp = test_utils:packet_router_data_env_up(
            DevAddr,
            ?NWK_SESSION_KEY,
            ?APP_SESSION_KEY,
            0,
            PubKeyBin,
            SigFun
        ),
        ok = grpcbox_client:send(Stream, EnvUp),
        timer:sleep(100),

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

grpc_multi_buy_join_test(_Config) ->
    ok = meck:new(pp_packet_reporter, [passthrough]),
    ok = meck:expect(pp_packet_reporter, report_packet, 4, ok),

    %% This test uses a udp socket to test how many packets are received since
    %% we're going through the grpc entry point, and don't send back mutli-buy
    %% messages.
    {ok, RecvPid} = pp_lns:start_link(#{port => 3333, forward => self()}),
    {ok, Stream} = helium_packet_router_packet_client:route(),

    DevEUI = <<0, 0, 0, 0, 0, 0, 0, 1>>,
    AppEUI = <<0, 0, 0, 2, 0, 0, 0, 1>>,

    MakeJoinEnvUp = fun() ->
        JoinNonce = crypto:strong_rand_bytes(2),
        AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

        #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        SigFun = libp2p_crypto:mk_sig_fun(PrivKey),

        test_utils:packet_router_join_env_up(
            AppKey,
            JoinNonce,
            DevEUI,
            AppEUI,
            PubKeyBin,
            SigFun
        )
    end,

    application:set_env(packet_purchaser, join_net_ids, #{
        {DevEUI, AppEUI} => ?NET_ID_COMCAST
    }),

    %% -------------------------------------------------------------------
    %% Send more than one of the same join, only 1 should be bought
    BaseConfig = #{
        <<"name">> => "two",
        <<"net_id">> => ?NET_ID_COMCAST,
        <<"address">> => <<"127.0.0.1">>,
        <<"port">> => 3333,
        <<"multi_buy">> => 1,
        <<"joins">> => [
            #{<<"dev_eui">> => bin_to_int(DevEUI), <<"app_eui">> => bin_to_int(AppEUI)}
        ]
    },

    ok = pp_config:load_config([BaseConfig]),
    EnvUp1 = MakeJoinEnvUp(),
    PushData = 0,

    SendAndRecv = fun(EnvUp) ->
        ok = grpcbox_client:send(Stream, EnvUp),
        case pp_lns:rcv(RecvPid, PushData) of
            {ok, _} -> got_data;
            E -> ct:fail({expected_data, E})
        end
    end,
    SendAndDoNotRecv = fun(EnvUp) ->
        ok = grpcbox_client:send(Stream, EnvUp),
        case pp_lns:not_rcv(RecvPid, PushData, 500) of
            ok -> no_data;
            E -> ct:fail({expected_no_data, E})
        end
    end,

    %% ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertEqual(got_data, SendAndRecv(EnvUp1)),
    %% ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp1)),
    %% ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer1, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp1)),

    %% %% -------------------------------------------------------------------
    %% %% Send more than one of the same join, 2 should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 2})]),
    EnvUp2 = MakeJoinEnvUp(),
    %% ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertEqual(got_data, SendAndRecv(EnvUp2)),
    %% ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertEqual(got_data, SendAndRecv(EnvUp2)),
    %% ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(Offer2, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp2)),

    %% %% -------------------------------------------------------------------
    %% %% Send more than one of the same join, none should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 0})]),
    EnvUp3 = MakeJoinEnvUp(),
    %% ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp3)),
    %% ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp3)),
    %% ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(Offer3, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp3)),

    %% -------------------------------------------------------------------
    %% Send more than one of the same join, unlimited should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => <<"unlimited">>})]),
    EnvUp4 = MakeJoinEnvUp(),
    lists:foreach(
        fun(_Idx) ->
            %% ?assertMatch(ok, pp_sc_packet_handler:handle_offer(Offer4, self()))
            ?assertEqual(got_data, SendAndRecv(EnvUp4))
        end,
        lists:seq(1, 100)
    ),
    case pp_utils:is_chain_dead() of
        true ->
            %% counted up all the packet sending that returned 'got_data'
            ?assertEqual(103, meck:num_calls(pp_packet_reporter, report_packet, 4)),
            meck:unload(pp_packet_reporter),
            ok;
        false ->
            ?assertEqual(0, meck:num_calls(pp_packet_reporter, report_packet, 4)),
            meck:unload(pp_packet_reporter),
            ok
    end,
    ok.

grpc_multi_buy_packet_test(_Config) ->
    %% This test uses a udp socket to test how many packets are received since
    %% we're going through the grpc entry point, and don't send back mutli-buy
    %% messages.
    {ok, RecvPid} = pp_lns:start_link(#{port => 3333, forward => self()}),
    {ok, Stream} = helium_packet_router_packet_client:route(),

    MakeDataEnvUp = fun(FCnt) ->
        #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
        SigFun = libp2p_crypto:mk_sig_fun(PrivKey),

        test_utils:packet_router_data_env_up(
            ?DEVADDR_COMCAST,
            ?NWK_SESSION_KEY,
            ?APP_SESSION_KEY,
            FCnt,
            PubKeyBin,
            SigFun
        )
    end,

    PushData = 0,
    SendAndRecv = fun(EnvUp) ->
        ok = grpcbox_client:send(Stream, EnvUp),
        case pp_lns:rcv(RecvPid, PushData) of
            {ok, _} -> got_data;
            E -> ct:fail({expected_data, E})
        end
    end,
    SendAndDoNotRecv = fun(EnvUp) ->
        ok = grpcbox_client:send(Stream, EnvUp),
        case pp_lns:not_rcv(RecvPid, PushData, 500) of
            ok -> no_data;
            E -> ct:fail({expected_no_data, E})
        end
    end,

    %% -------------------------------------------------------------------
    %% Send more than one of the same join packet, only 1 should be bought
    BaseConfig = #{
        <<"name">> => "test",
        <<"net_id">> => ?NET_ID_COMCAST,
        <<"address">> => <<"127.0.0.1">>,
        <<"port">> => 3333,
        <<"multi_buy">> => 1
    },
    ok = pp_config:load_config([BaseConfig]),
    EnvUp1 = MakeDataEnvUp(0),

    %% ?assertMatch(ok, pp_sc_packet_handler:handle_offer(EnvUp1, self())),
    ?assertEqual(got_data, SendAndRecv(EnvUp1)),
    %% ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(EnvUp1, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp1)),
    %% ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(EnvUp1, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp1)),

    %% -------------------------------------------------------------------
    %% Send more than one of the same packet, 2 should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 2})]),
    EnvUp2 = MakeDataEnvUp(1),

    %% ?assertMatch(ok, pp_sc_packet_handler:handle_offer(EnvUp2, self())),
    ?assertEqual(got_data, SendAndRecv(EnvUp2)),
    %% ?assertMatch(ok, pp_sc_packet_handler:handle_offer(EnvUp2, self())),
    ?assertEqual(got_data, SendAndRecv(EnvUp2)),
    %% ?assertMatch({error, multi_buy_max_packet}, pp_sc_packet_handler:handle_offer(EnvUp2, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp2)),

    %% -------------------------------------------------------------------
    %% Send more than one of the same packet, none should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => 0})]),
    EnvUp3 = MakeDataEnvUp(2),

    %% ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(EnvUp3, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp3)),
    %% ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(EnvUp3, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp3)),
    %% ?assertMatch({error, multi_buy_disabled}, pp_sc_packet_handler:handle_offer(EnvUp3, self())),
    ?assertEqual(no_data, SendAndDoNotRecv(EnvUp3)),

    %% -------------------------------------------------------------------
    %% Send more than one of the same packet, unlimited should be purchased
    ok = pp_config:load_config([maps:merge(BaseConfig, #{<<"multi_buy">> => <<"unlimited">>})]),
    EnvUp4 = MakeDataEnvUp(3),

    lists:foreach(
        fun(_Idx) ->
            %% ?assertMatch(ok, pp_sc_packet_handler:handle_offer(EnvUp4, self()))
            ?assertEqual(got_data, SendAndRecv(EnvUp4))
        end,
        lists:seq(1, 100)
    ),

    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

bin_to_int(Bin) ->
    pp_utils:hexstring_to_int(pp_utils:binary_to_hex(Bin)).
