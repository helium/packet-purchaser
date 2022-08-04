-module(helium_pp_service).

-behavior(helium_router_bhvr).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-ifdef(TEST).
-define(TIMEOUT, 5000).
-else.
%% Longest RXDelay is 15s
-define(TIMEOUT, 15000).
-endif.

-export([
    route/2
]).

route(Ctx, #blockchain_state_channel_message_v1_pb{msg = {packet, SCPacket}} = _Message) ->
    lager:debug("executing RPC route with msg ~p", [_Message]),

    BasePacket = SCPacket#blockchain_state_channel_packet_v1_pb{signature = <<>>},
    EncodedPacket = blockchain_state_channel_packet_v1:encode(BasePacket),
    Signature = blockchain_state_channel_packet_v1:signature(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    PubKey = libp2p_crypto:bin_to_pubkey(PubKeyBin),
    case libp2p_crypto:verify(EncodedPacket, Signature, PubKey) of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(2), <<"bad signature">>}};
        true ->
            %% handle the packet and then await a response
            %% if no response within given time, then give up and return error
            {Time, _} = timer:tc(pp_sc_packet_handler, handle_free_packet, [
                SCPacket,
                erlang:system_time(millisecond),
                self()
            ]),
            pp_metrics:function_observe('pp_sc_packet_handler:handle_free_packet', Time),
            wait_for_response(Ctx)
    end.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
wait_for_response(Ctx) ->
    receive
        {send_response, Resp} ->
            lager:debug("received response msg ~p", [Resp]),
            {ok, #blockchain_state_channel_message_v1_pb{msg = {response, Resp}}, Ctx};
        {packet, Packet} ->
            lager:debug("received packet ~p", [Packet]),
            {ok, #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}}, Ctx};
        {error, Reason} ->
            lager:debug("received error msg ~p", [Reason]),
            {grpc_error, {grpcbox_stream:code_to_status(2), erlang:atom_to_binary(Reason)}}
    after ?TIMEOUT ->
        %% The packet hasn't been rejected, but nobody has responded with a
        %% downlink. It was used, but requires nothing more than an
        %% acknowledgement.
        lager:debug("failed to receive response msg after ~p seconds", [?TIMEOUT]),
        Resp = blockchain_state_channel_response_v1:new(true),
        {ok, #blockchain_state_channel_message_v1_pb{msg = {response, Resp}}, Ctx}
    end.
