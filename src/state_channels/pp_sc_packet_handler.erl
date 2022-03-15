%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser State Channel Packet Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(pp_sc_packet_handler).

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

%% ------------------------------------------------------------------
%% Packet Handler Functions
%% ------------------------------------------------------------------

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok.
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
                "~s: buying disabled for ~p in net_id ~p",
                [PacketType, RoutingInfo, NetID]
            ),
            {error, buying_inactive};
        {error, routing_not_found} = Err ->
            lager:debug(
                "~s: routing information not found [routing_info: ~p]",
                [PacketType, RoutingInfo]
            ),
            Err;
        {error, unmapped_eui} = Err ->
            lager:debug(
                "~s: no mapping for [routing_info: ~p]",
                [PacketType, RoutingInfo]
            ),
            Err;
        {error, invalid_net_id_type} = Err ->
            lager:debug(
                "~s: inavlid net id type [routing_info: ~p]",
                [PacketType, RoutingInfo]
            ),
            Err;
        {udp, #{net_id := NetID} = WorkerArgs} ->
            case pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, WorkerArgs) of
                {ok, WorkerPid} ->
                    lager:debug(
                        "~s: [routing_info: ~p] [net_id: ~p]",
                        [PacketType, RoutingInfo, NetID]
                    ),
                    ok = pp_metrics:handle_packet(PubKeyBin, NetID, PacketType),
                    ok = pp_console_ws_worker:handle_packet(NetID, Packet, PacketTime, PacketType),
                    pp_udp_worker:push_data(WorkerPid, SCPacket, PacketTime, Pid);
                {error, worker_not_started} = Err ->
                    lager:error(
                        "failed to start udp connector for ~p: ~p",
                        [blockchain_utils:addr2name(PubKeyBin)]
                    ),
                    Err
            end;
        {http, #{address := _Address, port := _Port, net_id := _NetID} = Args} ->
            PHash = blockchain_helium_packet_v1:packet_hash(Packet),
            case pp_http_sup:maybe_start_worker(PHash, Args) of
                {error, worker_not_started, _} = Err ->
                    lager:error("failed to start http connector for ~p: ~p", [
                        blockchain_utils:addr2name(PubKeyBin),
                        Err
                    ]),
                    Err;
                {ok, WorkerPid} ->
                    pp_http_worker:handle_packet(WorkerPid, SCPacket, PacketTime)
            end
    end.

%% ------------------------------------------------------------------
%% Buying Functions
%% ------------------------------------------------------------------

handle_join_offer(EUI, Offer) ->
    case pp_config:lookup_eui(EUI) of
        {udp, #{multi_buy := MultiBuyMax}} ->
            pp_multi_buy:maybe_buy_offer(Offer, MultiBuyMax);
        {http, #{multi_buy := MultiBuyMax}} ->
            pp_multi_buy:maybe_buy_offer(Offer, MultiBuyMax);
        Err ->
            Err
    end.

handle_packet_offer(DevAddr, Offer) ->
    case pp_config:lookup_devaddr(DevAddr) of
        {udp, #{multi_buy := MultiBuyMax}} ->
            pp_multi_buy:maybe_buy_offer(Offer, MultiBuyMax);
        {http, #{multi_buy := MultiBuyMax}} ->
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
    PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),
    {ok, NetID} =
        case Routing of
            {eui, _} = EUI ->
                case pp_config:lookup_eui(EUI) of
                    {error, Reason} -> {ok, Reason};
                    {_, #{net_id := NetID0}} -> {ok, NetID0}
                end;
            {devaddr, DevAddr} ->
                case lorawan_devaddr:net_id(DevAddr) of
                    {error, Reason} -> {ok, Reason};
                    {_, NetID0} -> {ok, NetID0}
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

    PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
    ok = pp_metrics:handle_offer(PubKeyBin, NetID, OfferType, Action, PayloadSize),

    lager:debug("offer: ~s ~s [net_id: ~p] [routing: ~p] [resp: ~p]", [
        Action,
        OfferType,
        NetID,
        Routing,
        Resp
    ]).
