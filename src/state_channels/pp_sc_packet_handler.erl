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

%% Offer rejected reasons
-define(UNMAPPED_EUI, unmapped_eui).

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
        {devaddr, _} = DevAddr ->
            try
                {ok, #{net_id := NetID} = WorkerArgs} = pp_config:lookup_devaddr(DevAddr),
                lager:debug("packet: [devaddr: ~p] [netid: ~p]", [DevAddr, NetID]),
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
                {ok, #{net_id := NetID} = WorkerArgs} = pp_config:lookup_eui(EUI),
                lager:debug("join: [eui: ~p] [netid: ~p]", [EUI, NetID]),
                {ok, WorkerPid} = pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, WorkerArgs),
                pp_udp_worker:push_data(WorkerPid, Token, UDPData, Pid)
            catch
                error:{badkey, KeyNetID} ->
                    lager:debug("join: ignoring unconfigured NetID ~p", [KeyNetID]);
                error:{badmatch, {error, unmapped_eui}} ->
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
    case pp_config:lookup_eui(EUI) of
        {error, _} ->
            {error, ?UNMAPPED_EUI};
        {ok, #{multi_buy := MultiBuy}} ->
            pp_multi_buy:maybe_buy_offer(Offer, MultiBuy)
    end.

handle_packet_offer(DevAddr, Offer) ->
    case pp_config:lookup_devaddr(DevAddr) of
        {ok, #{multi_buy := MultiBuy}} ->
            pp_multi_buy:maybe_buy_offer(Offer, MultiBuy);
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
    {ok, #{net_id := NetID}} =
        case Routing of
            {eui, _} = EUI -> pp_config:lookup_eui(EUI);
            {devaddr, _} = DevAddr -> pp_config:lookup_devaddr(DevAddr)
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
