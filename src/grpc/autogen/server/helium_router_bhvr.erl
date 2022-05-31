%%%-------------------------------------------------------------------
%% @doc Behaviour to implement for grpc service helium.router.
%% @end
%%%-------------------------------------------------------------------

%% this module was generated on 2022-05-31T17:37:11+00:00 and should not be modified manually

-module(helium_router_bhvr).

-callback route(ctx:ctx(), router_pb:blockchain_state_channel_message_v1_pb()) ->
    {ok, router_pb:blockchain_state_channel_message_v1_pb(), ctx:ctx()}
    | grpcbox_stream:grpc_error_response().

-callback init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
-callback handle_info(any(), grpcbox_stream:t()) -> grpcbox_stream:t().
-optional_callbacks([init/2, handle_info/2]).
