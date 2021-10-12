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
    multi_buy_worst_case_stress_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").

-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

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
        join_net_id_offer_test,
        join_net_id_packet_test,
        net_ids_map_offer_test,
        net_ids_map_packet_test,
        net_ids_no_config_test,
        single_hotspot_multi_net_id_test,
        multi_buy_join_test,
        multi_buy_packet_test,
        multi_buy_eviction_test
        %% multi_buy_worst_case_stress_test
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

join_net_id_offer_test(_Config) ->
    SendJoinOfferFun = fun(DevEUI, AppEUI) ->
        DevNonce = crypto:strong_rand_bytes(2),
        AppKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,

        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Offer = join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI),
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
    Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin1, DevAddr, 0, Routing, #{dont_encode => true}),

    {error, not_found} = pp_udp_sup:lookup_worker({PubKeyBin1, NetID}),
    pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),
    {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin1, NetID}),

    {
        state,
        PubKeyBin1,
        _Socket,
        Address,
        Port,
        _PushData,
        _ScPid,
        _PullData,
        _PullDataTimer
    } = sys:get_state(Pid),
    ?assertEqual({"3.3.3.3", 3333}, {Address, Port}),

    %% ------------------------------------------------------------
    %% Send packet with unmapped EUI from a different gateway
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    Routing2 = blockchain_helium_packet_v1:make_routing_info({eui, DevEUI2, AppEUI2}),

    Packet2 = frame_packet(
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
        join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI)
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

    JoinOffer = join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI),
    PacketOffer = packet_offer(PubKeyBin, ?DEVADDR_COMCAST),
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
        packet_offer(PubKeyBin, ?DEVADDR_COMCAST)
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

        Offer = packet_offer(PubKeyBin, DevAddr),
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

net_ids_map_packet_test(_Config) ->
    SendPacketFun = fun(DevAddr, NetID) ->
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{dont_encode => true}),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin, NetID}),
        {
            state,
            PubKeyBin,
            _Socket,
            Address,
            Port,
            _PushData,
            _ScPid,
            _PullData,
            _PullDataTimer
        } = sys:get_state(Pid),
        {Address, Port}
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

        Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{dont_encode => true}),
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
        Packet = frame_packet(?UNCONFIRMED_UP, PubKeyBin, DevAddr, 0, #{dont_encode => true}),
        pp_sc_packet_handler:handle_packet(Packet, erlang:system_time(millisecond), self()),

        {ok, Pid} = pp_udp_sup:lookup_worker({PubKeyBin, NetID}),
        {
            state,
            PubKeyBin,
            _Socket,
            Address,
            Port,
            _PushData,
            _ScPid,
            _PullData,
            _PullDataTimer
        } = sys:get_state(Pid),
        {Address, Port}
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

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

frame_packet(MType, PubKeyBin, DevAddr, FCnt, Options) ->
    <<DevNum:32/integer-unsigned>> = DevAddr,
    Routing = blockchain_helium_packet_v1:make_routing_info({devaddr, DevNum}),
    frame_packet(MType, PubKeyBin, DevAddr, FCnt, Routing, Options).

frame_packet(MType, PubKeyBin, DevAddr, FCnt, Routing, Options) ->
    NwkSessionKey = <<81, 103, 129, 150, 35, 76, 17, 164, 210, 66, 210, 149, 120, 193, 251, 85>>,
    AppSessionKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,
    Payload1 = frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt),

    HeliumPacket = #packet_pb{
        type = lorawan,
        payload = Payload1,
        frequency = 923.3,
        datarate = maps:get(datarate, Options, "SF8BW125"),
        signal_strength = maps:get(rssi, Options, 0.0),
        snr = maps:get(snr, Options, 0.0),
        routing = Routing
    },
    Packet = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket,
        hotspot = PubKeyBin,
        region = 'US915'
    },
    case maps:get(dont_encode, Options, false) of
        true ->
            Packet;
        false ->
            Msg = #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}},
            blockchain_state_channel_v1_pb:encode_msg(Msg)
    end.

%% join_offer(PubKeyBin, AppKey, DevNonce) ->
%%     join_offer(PubKeyBin, AppKey, DevNonce, ?DEVEUI, ?APPEUI).

join_offer(PubKeyBin, AppKey, DevNonce, DevEUI, AppEUI) ->
    RoutingInfo = {eui, DevEUI, AppEUI},
    HeliumPacket = blockchain_helium_packet_v1:new(
        lorawan,
        join_payload(AppKey, DevNonce, DevEUI, AppEUI),
        1000,
        0,
        923.3,
        "SF8BW125",
        0.0,
        RoutingInfo
    ),

    blockchain_state_channel_offer_v1:from_packet(
        HeliumPacket,
        PubKeyBin,
        'US915'
    ).

packet_offer(PubKeyBin, DevAddr) ->
    NwkSessionKey = crypto:strong_rand_bytes(16),
    AppSessionKey = crypto:strong_rand_bytes(16),
    FCnt = 0,

    Payload = frame_payload(?UNCONFIRMED_UP, DevAddr, NwkSessionKey, AppSessionKey, FCnt),

    <<DevNum:32/integer-unsigned>> = DevAddr,
    Routing = blockchain_helium_packet_v1:make_routing_info({devaddr, DevNum}),

    HeliumPacket = #packet_pb{
        type = lorawan,
        payload = Payload,
        frequency = 923.3,
        datarate = "SF8BW125",
        signal_strength = 0.0,
        snr = 0.0,
        routing = Routing
    },

    blockchain_state_channel_offer_v1:from_packet(HeliumPacket, PubKeyBin, 'US915').

join_payload(AppKey, DevNonce, DevEUI0, AppEUI0) ->
    MType = ?JOIN_REQ,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = reverse(AppEUI0),
    DevEUI = reverse(DevEUI0),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:cmac(aes_cbc128, AppKey, Payload0, 4),
    <<Payload0/binary, MIC:4/binary>>.

frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt) ->
    MHDRRFU = 0,
    Major = 0,
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FOptsBin = <<>>,
    FOptsLen = byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = <<1:8>>,
    Data = reverse(
        cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)
    ),
    FCntSize = 16,
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
            FOptsLen:4, FCnt:FCntSize/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:cmac(aes_cbc128, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    <<Payload0/binary, MIC:4/binary>>.

%% ------------------------------------------------------------------
%% PP Utils
%% ------------------------------------------------------------------

-spec b0(integer(), binary(), integer(), integer()) -> binary().
b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

%% ------------------------------------------------------------------
%% Lorawan Utils
%% ------------------------------------------------------------------

reverse(Bin) -> reverse(Bin, <<>>).

reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) -> reverse(Rest, <<H/binary, Acc/binary>>).

cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I + 1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) ->
    Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

-spec ai(integer(), binary(), integer(), integer()) -> binary().
ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

-spec binxor(binary(), binary(), binary()) -> binary().
binxor(<<>>, <<>>, Acc) ->
    Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).
