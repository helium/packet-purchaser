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
    handle_packet/3
]).

%% ------------------------------------------------------------------
%% Packet Handler Functions
%% ------------------------------------------------------------------

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok.
handle_offer(Offer, _HandlerPid) ->
    #routing_information_pb{data = Routing} = blockchain_state_channel_offer_v1:routing(Offer),
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    case pp_packet_sup:maybe_start_worker(PHash, #{routing => Routing, phash => PHash}) of
        {ok, Pid} ->
            pp_packet_worker:handle_offer(Pid, Offer);
        {error, Reason} = Err ->
            lager:warning("could not start the pp_packet worker: ~p", [Reason]),
            Err
    end.

-spec handle_packet(blockchain_state_channel_packet_v1:packet(), pos_integer(), pid()) ->
    ok | {error, any()}.
handle_packet(SCPacket, PacketTime, HandlerPid) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    Routing = blockchain_helium_packet_v1:routing_info(Packet),

    ok = pp_roaming_downlink:insert_handler(PubKeyBin, HandlerPid),

    case pp_packet_sup:maybe_start_worker(PHash, #{routing => Routing, phash => PHash}) of
        {ok, PacketPid} ->
            pp_packet_worker:handle_packet(PacketPid, SCPacket, PacketTime, HandlerPid);
        {error, Reason} = Err ->
            lager:warning("could not start the pp_packet worker: ~p", [Reason]),
            Err
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
