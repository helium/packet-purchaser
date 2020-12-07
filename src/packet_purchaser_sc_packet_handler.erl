%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser State Channel Packet Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(packet_purchaser_sc_packet_handler).

-include("lorawan.hrl").

-export([
    handle_offer/2,
    handle_packet/3
]).

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok.
handle_offer(_Offer, _HandlerPid) ->
    ok.

-spec handle_packet(blockchain_state_channel_packet_v1:packet(), pos_integer(), pid()) -> ok.
handle_packet(SCPacket, _PacketTime, _Pid) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Hotspot = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    MAC = packet_purchaser_utils:pubkeybin_to_mac(Hotspot),
    Token = semtech_udp:token(),
    UDPData = semtech_udp:push_data(
        MAC,
        blockchain_helium_packet_v1:timestamp(Packet),
        blockchain_helium_packet_v1:frequency(Packet),
        blockchain_helium_packet_v1:datarate(Packet),
        blockchain_helium_packet_v1:signal_strength(Packet),
        blockchain_helium_packet_v1:snr(Packet),
        blockchain_helium_packet_v1:payload(Packet),
        Token
    ),
    packet_purchaser_connector_udp:push_data(Token, UDPData).
