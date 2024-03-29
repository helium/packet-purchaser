-module(test_utils).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("packet_purchaser.hrl").
-include("lorawan_vars.hrl").
-include("../src/grpc/autogen/server/packet_router_pb.hrl").

-define(CONSOLE_IP_PORT, <<"127.0.0.1:3001">>).
-define(CONSOLE_URL, <<"http://", ?CONSOLE_IP_PORT/binary>>).
-define(CONSOLE_WS_URL, <<"ws://", ?CONSOLE_IP_PORT/binary, "/websocket">>).
-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    match_map/2,
    wait_until/1, wait_until/3,
    %%
    ws_rcv/0,
    ws_init/0,
    ws_roaming_rcv/1,
    ws_test_rcv/0,
    ws_prepare_test_msg/1,
    %%
    frame_packet/5, frame_packet/6,
    join_offer/5,
    join_payload/4,
    packet_offer/2,
    %%
    ignore_messages/0,
    %%
    packet_router_join_env_up/6,
    packet_router_data_env_up/6,
    uplink_packet_up/1
]).

-spec init_per_testcase(atom(), list()) -> list().
init_per_testcase(TestCase, Config) ->
    persistent_term:put(pp_test_ics_gateway_service, self()),
    BaseDir = io_lib:format("~p-~p", [TestCase, erlang:system_time(millisecond)]),
    ok = application:set_env(?APP, testing, true),
    ok = application:set_env(blockchain, base_dir, BaseDir ++ "/blockchain_data"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    ok = application:set_env(lager, crash_log, "crash.log"),

    DefaultConsoleSettings = [
        {endpoint, ?CONSOLE_URL},
        {ws_endpoint, ?CONSOLE_WS_URL},
        {secret, <<>>},
        {auto_connect, "true"}
    ],
    OverrideConsoleSettings = proplists:get_value(console_api, Config, []),
    ok = application:set_env(
        packet_purchaser,
        pp_console_api,
        DefaultConsoleSettings ++ OverrideConsoleSettings
    ),

    FormatStr = [
        "[",
        date,
        " ",
        time,
        "] ",
        pid,
        " [",
        severity,
        "]",
        {device_id, [" [", device_id, "]"], ""},
        " [",
        {module, ""},
        {function, [":", function], ""},
        {line, [":", line], ""},
        "] ",
        message,
        "\n"
    ],
    case os:getenv("CT_LAGER", "NONE") of
        "DEBUG" ->
            ok = application:set_env(lager, handlers, [
                {lager_console_backend, [
                    {level, error},
                    {formatter_config, FormatStr}
                ]},
                {lager_file_backend, [
                    {file, "packet_purchaser.log"},
                    {level, error},
                    {formatter_config, FormatStr}
                ]}
            ]),
            ok = application:set_env(lager, traces, [
                {lager_console_backend, [{application, packet_purchaser}], debug},
                {{lager_file_backend, "packet_purchaser.log"}, [{application, packet_purchaser}],
                    debug}
            ]);
        _ ->
            ok
    end,

    ElliOpts = [
        {callback, console_callback},
        {callback_args, #{
            forward => self()
        }},
        {port, 3001},
        {min_acceptors, 1}
    ],
    {ok, ElliPid} = elli:start_link(ElliOpts),
    %% TODO: is this necessary? application:ensure_all_started(gun),

    {ok, FakeLNSPid} = pp_lns:start_link(#{port => 1700, forward => self()}),
    {ok, _} = application:ensure_all_started(?APP),

    SwarmKey = filename:join([
        application:get_env(blockchain, base_dir, "data"),
        "blockchain",
        "swarm_key"
    ]),
    ok = filelib:ensure_dir(SwarmKey),
    {ok, PPKeys} = libp2p_crypto:load_keys(SwarmKey),
    #{public := PPPubKey, secret := PPPrivKey} = PPKeys,
    Config0 =
        case proplists:get_value(is_chain_dead, Config, false) of
            true ->
                Config;
            false ->
                {ok, _GenesisMembers, ConsensusMembers, _Keys} = blockchain_test_utils:init_chain(
                    5000,
                    [{PPPrivKey, PPPubKey}]
                ),
                [{consensus_member, ConsensusMembers} | Config]
        end,

    GatewayConfig = proplists:get_value(gateway_config, Config, #{}),
    {PubKeyBin, WorkerPid} = start_gateway(GatewayConfig),

    DefaultEnv = application:get_all_env(?APP),
    ResetEnvFun = fun() ->
        [application:set_env(?APP, Key, Val) || {Key, Val} <- DefaultEnv],
        ok
    end,

    lager:info("starting test ~p", [TestCase]),
    [
        {lns, FakeLNSPid},
        {gateway, {PubKeyBin, WorkerPid}},
        {reset_env_fun, ResetEnvFun},
        {elli, ElliPid}
        | Config0
    ].

-spec end_per_testcase(atom(), list()) -> ok.
end_per_testcase(TestCase, Config) ->
    lager:info("stopping test ~p", [TestCase]),
    FakeLNSPid = proplists:get_value(lns, Config),
    ResetEnvFun = proplists:get_value(reset_env_fun, Config),
    ok = ResetEnvFun(),
    ok = gen_server:stop(FakeLNSPid),
    ok = application:stop(?APP),
    ok = application:stop(lager),
    ok = application:stop(prometheus),
    ok.

-spec match_map(map(), any()) -> true | {false, term()}.
match_map(Expected, Got) when is_map(Got) ->
    ESize = maps:size(Expected),
    GSize = maps:size(Got),
    case ESize == GSize of
        false ->
            Flavor =
                case ESize > GSize of
                    true -> {missing_keys, maps:keys(Expected) -- maps:keys(Got)};
                    false -> {extra_keys, maps:keys(Got) -- maps:keys(Expected)}
                end,
            {false, {size_mismatch, {expected, ESize}, {got, GSize}, Flavor}};
        true ->
            maps:fold(
                fun
                    (_K, _V, {false, _} = Acc) ->
                        Acc;
                    (K, V, true) when is_function(V) ->
                        case V(maps:get(K, Got, undefined)) of
                            true ->
                                true;
                            false ->
                                {false, {value_predicate_failed, K, maps:get(K, Got, undefined)}}
                        end;
                    (K, '_', true) ->
                        case maps:is_key(K, Got) of
                            true -> true;
                            false -> {false, {missing_key, K}}
                        end;
                    (K, V, true) when is_map(V) ->
                        match_map(V, maps:get(K, Got, #{}));
                    (K, V0, true) when is_list(V0) ->
                        V1 = lists:zip(lists:seq(1, erlang:length(V0)), lists:sort(V0)),
                        G0 = maps:get(K, Got, []),
                        G1 = lists:zip(lists:seq(1, erlang:length(G0)), lists:sort(G0)),
                        match_map(maps:from_list(V1), maps:from_list(G1));
                    (K, V, true) ->
                        case maps:get(K, Got, undefined) of
                            V -> true;
                            _ -> {false, {value_mismatch, K, V, maps:get(K, Got, undefined)}}
                        end
                end,
                true,
                Expected
            )
    end;
match_map(_Expected, _Got) ->
    {false, not_map}.

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

-spec ws_prepare_test_msg(binary()) -> ok.
ws_prepare_test_msg(Bin) ->
    pp_console_ws_client:encode_msg(<<"0">>, <<"test_utils">>, <<"test_message">>, Bin).

-spec ws_test_rcv() -> {ok, any()}.
ws_test_rcv() ->
    receive
        {websocket_msg, #{
            topic := <<"test_utils">>,
            event := <<"test_message">>,
            payload := Payload
        }} ->
            {ok, Payload}
    after 2500 -> ct:fail(websocket_test_message_timeout)
    end.

-spec ws_init() -> {ok, pid()}.
ws_init() ->
    R =
        receive
            {websocket_init, Pid} ->
                {ok, Pid}
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    %% Eat phx_join message and packet_purchaser address message
    {ok, #{event := <<"phx_join">>, topic := <<"organization:all">>}} = ws_roaming_rcv(org_join),
    {ok, #{event := <<"phx_join">>, topic := <<"net_id:all">>}} = ws_roaming_rcv(net_id_join),
    {ok, #{event := <<"packet_purchaser:address">>}} = ws_roaming_rcv(pp_address),
    {ok, #{event := <<"packet_purchaser:get_config">>}} = ws_roaming_rcv(pp_get_config),
    R.

-spec ws_rcv() -> {ok, any()}.
ws_rcv() ->
    receive
        {websocket_packet, Payload} ->
            %% {ok, #{payload := Payload}} = pp_console_websocket_client:decode_msg(Msg),
            {ok, Payload}
    after 2500 -> ct:fail(websocket_msg_timeout)
    end.

-spec ws_roaming_rcv(atom()) -> {ok, binary(), binary(), any()}.
ws_roaming_rcv(ErrId) ->
    receive
        {websocket_msg, Payload} ->
            {ok, Payload}
    after 2500 -> ct:fail({websocket_roaming_msg_timeout, ErrId})
    end.

ignore_messages() ->
    receive
        Msg ->
            ct:print("ignoring : ~p", [Msg]),
            ignore_messages()
    after 100 -> ok
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_gateway(map()) -> {libp2p_crypto:pubkeybin(), pid()}.
start_gateway(GatewayConfig) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    %% NetID to ensure sending packets from pp_lns get routed to this worker
    {ok, NetID} = pp_lorawan:parse_netid(16#deadbeef),
    {ok, WorkerPid} = pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, GatewayConfig),
    {PubKeyBin, WorkerPid}.

packet_router_join_env_up(AppKey, JoinNonce, DevEUI, AppEUI, PubKeyBin, SigFun) ->
    Packet = #packet_router_packet_up_v1_pb{
        payload = ?MODULE:join_payload(AppKey, JoinNonce, DevEUI, AppEUI),
        timestamp = 620124,
        rssi = 112,
        frequency = 903900024,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway = PubKeyBin,
        signature = <<>>
    },
    Signed = Packet#packet_router_packet_up_v1_pb{
        signature = SigFun(packet_router_pb:encode_msg(Packet))
    },
    #envelope_up_v1_pb{data = {packet, Signed}}.

packet_router_data_env_up(DevAddr, NwkSessionKey, AppSessionKey, FCnt, PubKeyBin, SigFun) ->
    Packet = #packet_router_packet_up_v1_pb{
        payload = frame_payload(
            ?UNCONFIRMED_UP,
            DevAddr,
            NwkSessionKey,
            AppSessionKey,
            FCnt
        ),
        timestamp = 620124,
        rssi = 112,
        frequency = 903900024,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway = PubKeyBin,
        signature = <<>>
    },
    Signed = Packet#packet_router_packet_up_v1_pb{
        signature = SigFun(packet_router_pb:encode_msg(Packet))
    },
    #envelope_up_v1_pb{data = {packet, Signed}}.

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

frame_payload(MType, <<DevNum:32/integer-big>>= DevAddr, NwkSessionKey, AppSessionKey, FCnt) ->
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
        <<MType:3, MHDRRFU:3, Major:2, DevNum:32/integer-little, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
            FOptsLen:4, FCnt:FCntSize/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:macN(cmac, aes_128_cbc, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    <<Payload0/binary, MIC:4/binary>>.

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
    MIC = crypto:macN(cmac, aes_128_cbc, AppKey, Payload0, 4),
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
    Si = crypto:crypto_one_time(aes_128_ecb, Key, ai(Dir, DevAddr, FCnt, I), true),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I + 1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) ->
    Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:crypto_one_time(aes_128_ecb, Key, ai(Dir, DevAddr, FCnt, I), true),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

-spec ai(integer(), binary(), integer(), integer()) -> binary().
ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

-spec binxor(binary(), binary(), binary()) -> binary().
binxor(<<>>, <<>>, Acc) ->
    Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).

%% -------------------------------------------------------------------
%% Generating HPR packets are a little different.
%% -------------------------------------------------------------------

-spec uplink_packet_up(Opts :: map()) -> hpr_packet_up:packet().
uplink_packet_up(Opts0) ->
    MType = maps:get(mtype, Opts0, ?UNCONFIRMED_UP),
    MHDRRFU = 0,
    Major = 0,
    DevAddr = maps:get(devaddr, Opts0, 16#00000000),
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FCnt = maps:get(fcnt, Opts0, 1),
    FOptsBin = <<>>,
    FOptsLen = erlang:byte_size(FOptsBin),
    Port = 0,
    Body = maps:get(data, Opts0, <<"data">>),
    AppSessionKey = maps:get(
        app_session_key,
        Opts0,
        crypto:strong_rand_bytes(16)
    ),
    Data = reverse(
        packet_up_cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)
    ),
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:32/little-unsigned-integer, ADR:1, ADRACKReq:1,
            ACK:1, RFU:1, FOptsLen:4, FCnt:16/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = packet_up_b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    NwkSessionKey = maps:get(
        nwk_session_key,
        Opts0,
        crypto:strong_rand_bytes(16)
    ),
    MIC = crypto:macN(cmac, aes_128_cbc, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),

    Payload = <<Payload0/binary, MIC:4/binary>>,
    Opts1 = maps:put(payload, maps:get(payload, Opts0, Payload), Opts0),
    PacketUp = pp_packet_up:test_new(Opts1),
    SigFun = maps:get(sig_fun, Opts0, fun(_) -> <<"signature">> end),
    pp_packet_up:sign(PacketUp, SigFun).

packet_up_cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    packet_up_cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

packet_up_cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:crypto_one_time(aes_128_ecb, Key, ai(Dir, DevAddr, FCnt, I), true),
    packet_up_cipher(Rest, Key, Dir, DevAddr, FCnt, I + 1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
packet_up_cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) ->
    Acc;
packet_up_cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:crypto_one_time(aes_128_ecb, Key, packet_up_ai(Dir, DevAddr, FCnt, I), true),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

-spec packet_up_ai(integer(), binary(), integer(), integer()) -> binary().
packet_up_ai(Dir, DevAddr, FCnt, I) ->
    Bin = <<DevAddr:32/integer-unsigned-big>>,
    <<16#01, 0, 0, 0, 0, Dir, Bin:4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

-spec packet_up_b0(integer(), integer(), integer(), integer()) -> binary().
packet_up_b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0, 0, 0, 0, Dir, DevAddr:32/little-unsigned-integer, FCnt:32/little-unsigned-integer,
        0, Len>>.
