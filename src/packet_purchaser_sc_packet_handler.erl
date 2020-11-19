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
    _Hotspot = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    MAC = 0,
    Tmst = blockchain_helium_packet_v1:timestamp(Packet),
    Freq = blockchain_helium_packet_v1:frequency(Packet),
    Datr = blockchain_helium_packet_v1:datarate(Packet),
    RSSI = blockchain_helium_packet_v1:signal_strength(Packet),
    SNR = blockchain_helium_packet_v1:snr(Packet),
    Payload = blockchain_helium_packet_v1:payload(Packet),
    UDPData = lorawan_gwmp:push_data(
        MAC,
        Tmst,
        Freq,
        Datr,
        RSSI,
        SNR,
        Payload
    ),
    packet_purchaser_connector_udp:send(UDPData).
