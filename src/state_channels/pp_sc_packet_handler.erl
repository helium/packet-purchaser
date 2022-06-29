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

%% ------------------------------------------------------------------
%% Packet Handler Functions
%% ------------------------------------------------------------------

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok.
handle_offer(Offer, _HandlerPid) ->
    #routing_information_pb{data = Routing} = blockchain_state_channel_offer_v1:routing(Offer),

    Continue =
        case Routing of
            {devaddr, DevAddr} ->
                case pp_lorawan:parse_netid(DevAddr) of
                    {ok, 0} -> {error, ignore_net_id};
                    {ok, 1} -> {error, ignore_net_id};
                    {error, _} = Err1 -> Err1;
                    _ -> ok
                end;
            _ ->
                ok
        end,

    case Continue of
        ok ->
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            case pp_packet_sup:maybe_start_worker(PHash, #{routing => Routing, phash => PHash}) of
                {ok, Pid} ->
                    pp_packet_worker:handle_offer(Pid, Offer);
                {error, Reason} = Err2 ->
                    lager:warning("could not start the pp_packet worker: ~p", [Reason]),
                    Err2
            end;
        Err3 ->
            Err3
    end.

-spec handle_packet(blockchain_state_channel_packet_v1:packet(), pos_integer(), pid()) ->
    ok | {error, any()}.
handle_packet(SCPacket, PacketTime, HandlerPid) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),

    ok = pp_roaming_downlink:insert_handler(PubKeyBin, HandlerPid),

    case pp_packet_sup:lookup_worker(PHash) of
        {ok, PacketPid} ->
            pp_packet_worker:handle_packet(PacketPid, SCPacket, PacketTime, HandlerPid);
        {error, Reason} = Err ->
            lager:warning("could not start the pp_packet worker: ~p", [Reason]),
            Err
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
