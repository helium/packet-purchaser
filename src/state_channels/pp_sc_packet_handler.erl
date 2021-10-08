%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser State Channel Packet Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(pp_sc_packet_handler).

-include("packet_purchaser.hrl").

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-export([
    handle_offer/2,
    handle_packet/3
]).

-export([
    handle_join_offer/2,
    handle_packet_offer/2,
    handle_offer_resp/3
]).

-export([
    join_eui_to_net_id/1
]).

%% Offer rejected reasons
-define(UNMAPPED_EUI, unmapped_eui).
%% -define(NET_ID_INVALID, net_id_invalid).

%% ------------------------------------------------------------------
%% Packet Handler Functions
%% ------------------------------------------------------------------

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok.
handle_offer(Offer, _HandlerPid) ->
    #routing_information_pb{data = Routing} = blockchain_state_channel_offer_v1:routing(Offer),
    Resp =
        case Routing of
            {eui, EUI} -> ?MODULE:handle_join_offer(EUI, Offer);
            {devaddr, DevAddr} -> ?MODULE:handle_packet_offer(DevAddr, Offer)
        end,
    erlang:spawn(fun() ->
        ?MODULE:handle_offer_resp(Routing, Offer, Resp)
    end),
    Resp.

-spec handle_packet(blockchain_state_channel_packet_v1:packet(), pos_integer(), pid()) -> ok.
handle_packet(SCPacket, PacketTime, Pid) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Token = semtech_udp:token(),
    MAC = pp_utils:pubkeybin_to_mac(PubKeyBin),
    Tmst = blockchain_helium_packet_v1:timestamp(Packet),
    Payload = blockchain_helium_packet_v1:payload(Packet),
    UDPData = semtech_udp:push_data(
        Token,
        MAC,
        #{
            time => iso8601:format(
                calendar:system_time_to_universal_time(PacketTime, millisecond)
            ),
            tmst => Tmst band 16#FFFFFFFF,
            freq => blockchain_helium_packet_v1:frequency(Packet),
            rfch => 0,
            modu => <<"LORA">>,
            codr => <<"4/5">>,
            stat => 1,
            chan => 0,
            datr => erlang:list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
            rssi => erlang:trunc(blockchain_helium_packet_v1:signal_strength(Packet)),
            lsnr => blockchain_helium_packet_v1:snr(Packet),
            size => erlang:byte_size(Payload),
            data => base64:encode(Payload)
        }
    ),

    case blockchain_helium_packet_v1:routing_info(Packet) of
        {devaddr, DevAddr} ->
            try
                {ok, NetID} = lorawan_devaddr:net_id(<<DevAddr:32/integer-unsigned>>),
                lager:debug("packet: [devaddr: ~p] [netid: ~p]", [DevAddr, NetID]),
                {ok, WorkerArgs} = pp_config:lookup_routing(NetID),
                {ok, WorkerPid} = pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, WorkerArgs),
                ok = pp_metrics:handle_packet(PubKeyBin, NetID),
                pp_udp_worker:push_data(WorkerPid, Token, UDPData, Pid)
            catch
                error:{badkey, KeyNetID} ->
                    lager:debug("packet: ignoring unconfigured NetID ~p", [KeyNetID]);
                error:{badmatch, {error, routing_not_found}} ->
                    lager:warning("packet: routing information not found for packet");
                error:{badmatch, {error, worker_not_started, _Reason} = Error} ->
                    lager:error("failed to start udp connector for ~p: ~p", [
                        blockchain_utils:addr2name(PubKeyBin),
                        _Reason
                    ]),
                    Error
            end;
        {eui, _, _} = EUI ->
            try
                {ok, NetID} = join_eui_to_net_id(EUI),
                lager:debug("join: [eui: ~p] [netid: ~p]", [EUI, NetID]),
                {ok, WorkerArgs} = pp_config:lookup_routing(NetID),
                {ok, WorkerPid} = pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, WorkerArgs),
                pp_udp_worker:push_data(WorkerPid, Token, UDPData, Pid)
            catch
                error:{badkey, KeyNetID} ->
                    lager:debug("join: ignoring unconfigured NetID ~p", [KeyNetID]);
                error:{badmatch, {error, no_mapping}} ->
                    lager:debug("join: ignoring no mapping for EUI ~p", [EUI]);
                error:{badmatch, {error, routing_not_found}} ->
                    lager:warning("join: routing information not found for join");
                error:{badmatch, {error, worker_not_started, _Reason} = Error} ->
                    lager:error("failed to start udp connector for ~p: ~p", [
                        blockchain_utils:addr2name(PubKeyBin),
                        _Reason
                    ]),
                    Error
            end
    end.

%% ------------------------------------------------------------------
%% Buying Functions
%% ------------------------------------------------------------------

handle_join_offer(EUI, Offer) ->
    case join_eui_to_net_id(EUI) of
        {error, _} ->
            {error, ?UNMAPPED_EUI};
        {ok, NetID} ->
            pp_multi_buy:maybe_buy_offer(Offer, NetID)
    end.

handle_packet_offer(DevAddr, Offer) ->
    case lorawan_devaddr:net_id(<<DevAddr:32/integer-unsigned>>) of
        {ok, NetID} ->
            pp_multi_buy:maybe_buy_offer(Offer, NetID);
        Err ->
            Err
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_offer_resp(
    Routing :: {devaddr, non_neg_integer()} | {eui, blockchain_state_channel_v1_pb:eui_pb()},
    Offer :: blockchain_state_channel_offer_v1:offer(),
    Resp :: ok | {error, any()}
) -> ok.
handle_offer_resp(Routing, Offer, Resp) ->
    PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),
    {ok, NetID} =
        case Routing of
            {eui, EUI} ->
                case join_eui_to_net_id(EUI) of
                    {error, no_mapping} -> {ok, no_mapping};
                    V -> V
                end;
            {devaddr, DevAddr0} ->
                case lorawan_devaddr:net_id(DevAddr0) of
                    {error, Err} -> {ok, Err};
                    V -> V
                end
        end,
    ok = pp_metrics:handle_offer(PubKeyBin, NetID),

    Action =
        case Resp of
            ok -> buying;
            {error, _} -> ignoring
        end,
    OfferType =
        case Routing of
            {eui, _} -> join;
            {devaddr, _} -> packet
        end,

    lager:debug("offer: ~s ~s [net_id: ~p] [routing: ~p] [resp: ~p]", [
        Action,
        OfferType,
        NetID,
        Routing,
        Resp
    ]).

-spec join_eui_to_net_id(#eui_pb{} | {eui, non_neg_integer(), non_neg_integer()}) ->
    {ok, non_neg_integer()} | {error, no_mapping}.
join_eui_to_net_id(#eui_pb{deveui = Dev, appeui = App}) ->
    join_eui_to_net_id({eui, Dev, App});
join_eui_to_net_id({eui, _DevEUI, _AppEUI} = J) ->
    case pp_config:lookup_join(J) of
        undefined -> {error, no_mapping};
        NetID -> {ok, NetID}
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

join_eui_to_net_id_test() ->
    {ok, _} = pp_config:start_link(testing),
    Dev1 = 7,
    App1 = 13,
    Dev2 = 13,
    App2 = 17,
    EUI1 = #eui_pb{deveui = Dev1, appeui = App1},
    EUI2 = #eui_pb{deveui = Dev2, appeui = App2},

    NoneMapped = #{},
    OneMapped = #{
        <<"joins">> => [#{<<"app_eui">> => App1, <<"dev_eui">> => Dev1, <<"net_id">> => 2}],
        <<"routing">> => [#{<<"net_id">> => 2, <<"address">> => <<>>, <<"port">> => 1337}]
    },
    BothMapped = #{
        <<"joins">> => [
            #{<<"app_eui">> => App1, <<"dev_eui">> => Dev1, <<"net_id">> => 2},
            #{<<"app_eui">> => App2, <<"dev_eui">> => Dev2, <<"net_id">> => 99}
        ],
        <<"routing">> => [
            #{<<"net_id">> => 1, <<"address">> => <<>>, <<"port">> => 1337},
            #{<<"net_id">> => 99, <<"address">> => <<>>, <<"port">> => 1337}
        ]
    },
    WildcardMapped = #{
        <<"joins">> => [
            #{<<"app_eui">> => App1, <<"dev_eui">> => '*', <<"net_id">> => 2},
            #{<<"app_eui">> => App2, <<"dev_eui">> => '*', <<"net_id">> => 99}
        ],
        <<"routing">> => [
            #{<<"net_id">> => 1, <<"address">> => <<>>, <<"port">> => 1337},
            #{<<"net_id">> => 99, <<"address">> => <<>>, <<"port">> => 1337}
        ]
    },

    ok = pp_config:load_config(NoneMapped),
    ?assertMatch({error, _}, join_eui_to_net_id(EUI1), "Empty mapping, no joins"),

    ok = pp_config:load_config(OneMapped),
    ?assertMatch({ok, _}, join_eui_to_net_id(EUI1), "One EUI mapping, this one"),
    ?assertMatch({error, _}, join_eui_to_net_id(EUI2), "One EUI mapping, not this one"),

    ok = pp_config:load_config(BothMapped),
    ?assertMatch({ok, _}, join_eui_to_net_id(EUI1), "All EUI Mapped 1"),
    ?assertMatch({ok, _}, join_eui_to_net_id(EUI2), "All EUI Mapped 2"),

    ok = pp_config:load_config(WildcardMapped),
    ?assertMatch({ok, _}, join_eui_to_net_id(EUI1), "Wildcard EUI Mapped 1"),
    ?assertMatch(
        {ok, _},
        join_eui_to_net_id(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = App1
            }
        ),
        "Wildcard random device EUI Mapped 1"
    ),
    ?assertMatch({ok, _}, join_eui_to_net_id(EUI2), "Wildcard EUI Mapped 2"),
    ?assertMatch(
        {ok, _},
        join_eui_to_net_id(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = App2
            }
        ),
        "Wildcard random device EUI Mapped 2"
    ),
    ?assertMatch(
        {error, _},
        join_eui_to_net_id(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = rand:uniform(trunc(math:pow(2, 64) - 1000)) + 1000
            }
        ),
        "Wildcard random device EUI and unknown join eui no joins"
    ),

    ok.

net_id_udp_args_test() ->
    application:set_env(?APP, net_ids, not_a_map),
    ?assertEqual({error, routing_not_found}, pp_config:lookup_routing(35)),

    pp_config:load_config(#{
        <<"routing">> => [#{<<"net_id">> => 35, <<"address">> => <<"one.two">>, <<"port">> => 1122}]
    }),
    ?assertEqual({ok, #{address => "one.two", port => 1122}}, pp_config:lookup_routing(35)),

    ok.

-endif.
