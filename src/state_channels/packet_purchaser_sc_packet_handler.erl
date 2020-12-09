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
handle_packet(SCPacket, _PacketTime, Pid) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Token = semtech_udp:token(),
    MAC = packet_purchaser_utils:pubkeybin_to_mac(PubKeyBin),
    Tmst = blockchain_helium_packet_v1:timestamp(Packet),
    Payload = blockchain_helium_packet_v1:payload(Packet),
    UDPData = semtech_udp:push_data(
        Token,
        MAC,
        #{
            time => iso8601:format(calendar:system_time_to_universal_time(Tmst, millisecond)),
            tmst => Tmst,
            freq => blockchain_helium_packet_v1:frequency(Packet),
            stat => 0,
            modu => <<"LORA">>,
            datr => blockchain_helium_packet_v1:datarate(Packet),
            rssi => blockchain_helium_packet_v1:signal_strength(Packet),
            lsnr => blockchain_helium_packet_v1:snr(Packet),
            size => erlang:byte_size(Payload),
            data => base64:encode(Payload)
        }
    ),
    case packet_purchaser_udp_sup:maybe_start_worker(PubKeyBin, #{}) of
        {ok, WorkerPid} ->
            packet_purchaser_udp_worker:push_data(WorkerPid, Token, UDPData, Pid);
        {error, _Reason} = Error ->
            lager:error("failed to start udp connector for ~p: ~p", [
                blockchain_utils:addr2name(PubKeyBin),
                _Reason
            ]),
            Error
    end.
