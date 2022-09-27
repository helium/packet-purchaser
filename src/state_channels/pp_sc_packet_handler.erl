%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser State Channel Packet Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(pp_sc_packet_handler).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include("config.hrl").

-export([
    handle_offer/2,
    handle_packet/3,
    handle_free_packet/3
]).

-export([
    handle_join_offer/2,
    handle_packet_offer/2,
    handle_offer_resp/3
]).

%% ------------------------------------------------------------------
%% Packet Handler Functions
%% ------------------------------------------------------------------

-spec handle_free_packet(blockchain_state_channel_packet_v1:packet(), pos_integer(), pid()) ->
    ok | {error, any()}.
handle_free_packet(SCPacket, PacketTime, Pid) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    Offer = blockchain_state_channel_offer_v1:from_packet(Packet, PubKeyBin, Region),

    case ?MODULE:handle_offer(Offer, Pid) of
        {error, _} = Err ->
            Pid ! Err,
            Err;
        ok ->
            Ledger = pp_utils:get_ledger(),
            erlang:spawn(blockchain_state_channels_server, track_offer, [Offer, Ledger, self()]),
            ?MODULE:handle_packet(SCPacket, PacketTime, Pid),
            ok
    end.

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
handle_offer(Offer, _HandlerPid) ->
    #routing_information_pb{data = Routing} = blockchain_state_channel_offer_v1:routing(Offer),
    Resp =
        case Routing of
            {eui, _} = EUI -> ?MODULE:handle_join_offer(EUI, Offer);
            {devaddr, _} = DevAddr -> ?MODULE:handle_packet_offer(DevAddr, Offer)
        end,
    erlang:spawn(fun() ->
        ?MODULE:handle_offer_resp(Routing, Offer, Resp)
    end),
    Resp.

-spec handle_packet(blockchain_state_channel_packet_v1:packet(), pos_integer(), pid()) ->
    ok | {error, any()}.
handle_packet(SCPacket, PacketTime, Pid) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),

    {PacketType, RoutingInfo} =
        case blockchain_helium_packet_v1:routing_info(Packet) of
            {devaddr, _} = RI -> {packet, RI};
            {eui, _, _} = RI -> {join, RI}
        end,

    case pp_config:lookup(RoutingInfo) of
        {error, {buying_inactive, NetID}} ->
            lager:debug(
                [{packet_type, PacketType}, {net_id, NetID}, {error, buying_inactive}],
                "~s: buying disabled for ~p in net_id ~p",
                [PacketType, RoutingInfo, NetID]
            ),
            {error, buying_inactive};
        {error, {not_configured, NetID}} ->
            lager:debug(
                [{packet_type, PacketType, {net_id, NetID}, {error, not_configured}}],
                "~s: net_id ~p not configured",
                [PacketType, NetID]
            ),
            {error, not_configured};
        {error, routing_not_found} = Err ->
            lager:debug(
                [{packet_type, PacketType}, Err],
                "~s: routing information not found [routing_info: ~p]",
                [PacketType, RoutingInfo]
            ),
            Err;
        {error, unmapped_eui} = Err ->
            lager:debug(
                [{packet_type, PacketType}, Err],
                "~s: no mapping for [routing_info: ~p]",
                [PacketType, RoutingInfo]
            ),
            Err;
        {error, invalid_netid_type} = Err ->
            lager:debug(
                [{packet_type, PacketType}, Err],
                "~s: invalid net id type [routing_info: ~p]",
                [PacketType, RoutingInfo]
            ),
            Err;
        {ok, Matches} ->
            lists:foreach(
                fun(Match) ->
                    case Match of
                        #{net_id := NetID, protocol := {udp, _, _} = Protocol} = WorkerArgs ->
                            case pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, WorkerArgs) of
                                {ok, WorkerPid} ->
                                    lager:debug(
                                        [
                                            {packet_type, PacketType},
                                            {net_id, NetID},
                                            {protocol, udp}
                                        ],
                                        "~s: [routing_info: ~p] [net_id: ~p]",
                                        [PacketType, RoutingInfo, NetID]
                                    ),
                                    ok = pp_metrics:handle_packet(
                                        PubKeyBin,
                                        NetID,
                                        PacketType,
                                        udp
                                    ),
                                    ok = pp_console_ws_worker:handle_packet(
                                        NetID,
                                        Packet,
                                        PacketTime,
                                        PacketType
                                    ),
                                    pp_udp_worker:push_data(
                                        WorkerPid,
                                        SCPacket,
                                        PacketTime,
                                        Pid,
                                        Protocol
                                    );
                                {error, worker_not_started} = Err ->
                                    lager:error(
                                        [{packet_type, PacketType}, {net_id, NetID}],
                                        "failed to start udp connector for ~p: ~p",
                                        [blockchain_utils:addr2name(PubKeyBin)]
                                    ),
                                    Err
                            end;
                        #{net_id := NetID, protocol := #http_protocol{} = Protocol} = Args ->
                            PHash = blockchain_helium_packet_v1:packet_hash(Packet),
                            case pp_http_sup:maybe_start_worker({NetID, PHash, Protocol}, Args) of
                                {error, worker_not_started, _} = Err ->
                                    lager:error(
                                        [{packet_type, PacketType}, {net_id, NetID}],
                                        "failed to start http connector for ~p: ~p",
                                        [blockchain_utils:addr2name(PubKeyBin), Err]
                                    ),
                                    Err;
                                {ok, WorkerPid} ->
                                    lager:debug(
                                        [
                                            {packet_type, PacketType},
                                            {net_id, NetID},
                                            {protocol, http}
                                        ],
                                        "~s: [routing_info: ~p] [net_id: ~p]",
                                        [PacketType, RoutingInfo, NetID]
                                    ),
                                    ProtocolType =
                                        case Protocol#http_protocol.flow_type of
                                            sync -> http_sync;
                                            async -> http_async
                                        end,
                                    ok = pp_metrics:handle_packet(
                                        PubKeyBin,
                                        NetID,
                                        PacketType,
                                        ProtocolType
                                    ),
                                    ok = pp_console_ws_worker:handle_packet(
                                        NetID,
                                        Packet,
                                        PacketTime,
                                        PacketType
                                    ),
                                    pp_http_worker:handle_packet(WorkerPid, SCPacket, PacketTime, Pid)
                            end
                    end
                end,
                Matches
            ),
            ok
    end.

%% ------------------------------------------------------------------
%% Buying Functions
%% ------------------------------------------------------------------

handle_join_offer(EUI, Offer) ->
    case pp_config:lookup_eui(EUI) of
        {ok, Matches} ->
            MultiBuyMax = lists:max([maps:get(multi_buy, M) || M <- Matches]),
            pp_multi_buy:maybe_buy_offer(Offer, MultiBuyMax);
        Err ->
            Err
    end.

handle_packet_offer(DevAddr, Offer) ->
    case pp_config:lookup_devaddr(DevAddr) of
        {ok, Matches} ->
            MultiBuyMax = lists:max([maps:get(multi_buy, M) || M <- Matches]),
            pp_multi_buy:maybe_buy_offer(Offer, MultiBuyMax);
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
    {ok, NetIDs} =
        case Routing of
            {eui, _} = EUI ->
                case pp_config:lookup_eui(EUI) of
                    {error, Reason} ->
                        {ok, [Reason]};
                    {ok, Ms} ->
                        NetIds = [NetID0 || #{net_id := NetID0} <- Ms],
                        {ok, NetIds}
                end;
            {devaddr, DevAddr} ->
                case lora_subnet:parse_netid(DevAddr, big) of
                    {error, Reason} -> {ok, [Reason]};
                    {_, NetID0} -> {ok, [NetID0]}
                end
        end,

    Action =
        case Resp of
            ok -> accepted;
            {error, _} -> rejected
        end,
    OfferType =
        case Routing of
            {eui, _} -> join;
            {devaddr, _} -> packet
        end,

    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    lists:foreach(
        fun(NetID) ->
            ok = pp_metrics:handle_offer(NetID, OfferType, Action, PHash),

            lager:debug(
                [{action, Action}, {offer_type, OfferType}, {net_id, NetID}],
                "offer: ~s ~s [net_id: ~p] [routing: ~p] [resp: ~p]",
                [Action, OfferType, NetID, Routing, Resp]
            )
        end,
        NetIDs
    ).
