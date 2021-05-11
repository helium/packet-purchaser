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

%% Offer rejected reasons
-define(NOT_ACCEPTING_JOINS, not_accepting_joins).
-define(NET_ID_REJECTED, net_id_rejected).

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok.
handle_offer(Offer, _HandlerPid) ->
    case blockchain_state_channel_offer_v1:routing(Offer) of
        #routing_information_pb{data = {eui, _EUI}} ->
            case pp_utils:accept_joins() of
                true -> ok;
                false -> {error, ?NOT_ACCEPTING_JOINS}
            end;
        #routing_information_pb{data = {devaddr, DevAddr}} ->
            case pp_utils:allowed_net_ids() of
                allow_all ->
                    ok;
                IDs ->
                    <<_AddrBase:25/integer-unsigned-little, NetID:7/integer-unsigned-little>> =
                        <<DevAddr:32/integer-unsigned-little>>,
                    case lists:member(NetID, IDs) of
                        true -> ok;
                        false -> {error, ?NET_ID_REJECTED}
                    end
            end
    end.

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
            time => iso8601:format(calendar:system_time_to_universal_time(Tmst, millisecond)),
            tmst => PacketTime band 4294967295,
            freq => blockchain_helium_packet_v1:frequency(Packet),
            rfch => 0,
            modu => <<"LORA">>,
            datr => blockchain_helium_packet_v1:datarate(Packet),
            rssi => erlang:trunc(blockchain_helium_packet_v1:signal_strength(Packet)),
            lsnr => blockchain_helium_packet_v1:snr(Packet),
            size => erlang:byte_size(Payload),
            data => base64:encode(Payload)
        }
    ),
    case pp_udp_sup:maybe_start_worker(PubKeyBin, #{}) of
        {ok, WorkerPid} ->
            pp_udp_worker:push_data(WorkerPid, Token, UDPData, Pid);
        {error, _Reason} = Error ->
            lager:error("failed to start udp connector for ~p: ~p", [
                blockchain_utils:addr2name(PubKeyBin),
                _Reason
            ]),
            Error
    end.
