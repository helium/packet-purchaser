%%%-------------------------------------------------------------------
%% @doc Client module for grpc service helium.router.
%% @end
%%%-------------------------------------------------------------------

%% this module was generated on 2022-05-31T17:37:09+00:00 and should not be modified manually

-module(helium_router_client).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("grpcbox/include/grpcbox.hrl").

-define(is_ctx(Ctx), is_tuple(Ctx) andalso element(1, Ctx) =:= ctx).

-define(SERVICE, 'helium.router').
-define(PROTO_MODULE, 'router_client_pb').
-define(MARSHAL_FUN(T), fun(I) -> ?PROTO_MODULE:encode_msg(I, T) end).
-define(UNMARSHAL_FUN(T), fun(I) -> ?PROTO_MODULE:decode_msg(I, T) end).
-define(DEF(Input, Output, MessageType), #grpcbox_def{
    service = ?SERVICE,
    message_type = MessageType,
    marshal_fun = ?MARSHAL_FUN(Input),
    unmarshal_fun = ?UNMARSHAL_FUN(Output)
}).

-spec route(router_client_pb:blockchain_state_channel_message_v1_pb()) ->
    {ok, router_client_pb:blockchain_state_channel_message_v1_pb(), grpcbox:metadata()}
    | grpcbox_stream:grpc_error_response()
    | {error, any()}.
route(Input) ->
    route(ctx:new(), Input, #{}).

-spec route(
    ctx:t() | router_client_pb:blockchain_state_channel_message_v1_pb(),
    router_client_pb:blockchain_state_channel_message_v1_pb() | grpcbox_client:options()
) ->
    {ok, router_client_pb:blockchain_state_channel_message_v1_pb(), grpcbox:metadata()}
    | grpcbox_stream:grpc_error_response()
    | {error, any()}.
route(Ctx, Input) when ?is_ctx(Ctx) ->
    route(Ctx, Input, #{});
route(Input, Options) ->
    route(ctx:new(), Input, Options).

-spec route(
    ctx:t(),
    router_client_pb:blockchain_state_channel_message_v1_pb(),
    grpcbox_client:options()
) ->
    {ok, router_client_pb:blockchain_state_channel_message_v1_pb(), grpcbox:metadata()}
    | grpcbox_stream:grpc_error_response()
    | {error, any()}.
route(Ctx, Input, Options) ->
    grpcbox_client:unary(
        Ctx,
        <<"/helium.router/route">>,
        Input,
        ?DEF(
            blockchain_state_channel_message_v1_pb,
            blockchain_state_channel_message_v1_pb,
            <<"helium.blockchain_state_channel_message_v1">>
        ),
        Options
    ).
