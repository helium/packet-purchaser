-module(pp_test_ics_gateway_service).

-behaviour(helium_iot_config_gateway_bhvr).
-include("../src/grpc/autogen/server/iot_config_pb.hrl").

-export([
    init/2,
    handle_info/2
]).

-export([
    region_params/2,
    load_region/2,
    location/2,info/2,info_stream/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, StreamState) ->
    StreamState.

region_params(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

load_region(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

info(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

info_stream(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

location(Ctx, Req) ->
    ct:print("got location request: ~p", [Req]),
    case verify_location_req(Req) of
        true ->
            case pp_utils:get_env_bool(test_location_not_found, false) of
                false ->
                    lager:info("got location req ~p", [Req]),
                    Res = #gateway_location_res_v1_pb{
                        location = "8828308281fffff"
                    },
                    persistent_term:get(?MODULE) ! {?MODULE, location, Req},
                    {ok, Res, Ctx};
                true ->
                    %% 5, not_found
                    {grpc_error, {grpcbox_stream:code_to_status(5), <<"gateway not asserted">>}}
            end;
        false ->
            lager:error("failed to verify location req ~p", [Req]),
            {grpc_error, {grpcbox_stream:code_to_status(7), <<"PERMISSION_DENIED">>}}
    end.

-spec verify_location_req(Req :: #gateway_location_req_v1_pb{}) -> boolean().
verify_location_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#gateway_location_req_v1_pb{
            signature = <<>>
        },
        gateway_location_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#gateway_location_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#gateway_location_req_v1_pb.signer)
    ).
