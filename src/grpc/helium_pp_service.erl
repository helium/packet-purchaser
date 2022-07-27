-module(helium_pp_service).

-behavior(helium_router_bhvr).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-ifdef(TEST).
-define(TIMEOUT, 5000).
-else.
-define(TIMEOUT, 8000).
-endif.

-export([
    route/2
]).

route(Ctx, #blockchain_state_channel_message_v1_pb{msg = {packet, SCPacket}} = _Message) ->
    lager:info("executing RPC route with msg ~p", [_Message]),
    %% handle the packet and then await a response
    %% if no response within given time, then give up and return error
    {Time, _} = timer:tc(pp_sc_packet_handler, handle_free_packet, [
        SCPacket, erlang:system_time(millisecond), self()
    ]),
    pp_metrics:function_observe('pp_sc_packet_handler:handle_free_packet', Time),
    wait_for_response(Ctx).

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
        {error, _Reason} ->
            lager:debug("received error msg ~p", [_Reason]),
            {grpc_error, {grpcbox_stream:code_to_status(2), <<"no response">>}}
    after ?TIMEOUT ->
        lager:debug("failed to receive response msg after ~p seconds", [?TIMEOUT]),
        {grpc_error, {grpcbox_stream:code_to_status(2), <<"no response">>}}
    end.