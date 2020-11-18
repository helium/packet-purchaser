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
handle_packet(_SCPacket, _PacketTime, _Pid) ->
    ok.
