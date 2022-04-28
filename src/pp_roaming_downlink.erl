-module(pp_roaming_downlink).

-include_lib("elli/include/elli.hrl").

-behaviour(elli_handler).

%% Downlink API
-export([
    handle/2,
    handle_event/3
]).

%% State Channel API
-export([
    init_ets/0,
    insert_handler/2,
    delete_handler/1,
    lookup_handler/1
]).

-define(SC_HANDLER_ETS, pp_http_sc_handler_ets).

%% Downlink Handler ==================================================

handle(Req, Args) ->
    Method = elli_request:method(Req),
    Host = elli_request:get_header(<<"Host">>, Req),
    lager:info("request from [host: ~p]", [Host]),

    case erlang:byte_size(Host) of
        0 ->
            {400, [], <<>>};
        _ ->
            Allowed = application:get_env(packet_purchaser, http_roaming_ip_list, []),
            case string:find(Allowed, Host) of
                nomatch ->
                    {400, [], <<>>};
                _ ->
                    lager:debug("request: ~p", [{Method, elli_request:path(Req), Req, Args}]),
                    Body = elli_request:body(Req),
                    Decoded = jsx:decode(Body),

                    case pp_roaming_protocol:handle_message(Decoded) of
                        {downlink, {SCPid, SCResp}} ->
                            lager:debug("sending downlink [sc_pid: ~p]", [SCPid]),
                            ok = blockchain_state_channel_common:send_response(SCPid, SCResp),
                            {200, [], <<>>};
                        {downlink, Response, {SCPid, SCResp}} ->
                            lager:debug(
                                "sending downlink [sc_pid: ~p] [response: ~p]",
                                [SCPid, Response]
                            ),
                            ok = blockchain_state_channel_common:send_response(SCPid, SCResp),
                            case application:get_env(packet_purchaser, http_downlink_flow_type) of
                                {ok, sync} ->
                                    {200, [], jsx:encode(Response)};
                                {ok, async} ->
                                    spawn(fun() ->
                                        SenderNetIDBin = maps:get(<<"SenderID">>, Decoded),
                                        SenderNetID = hexstring_to_int(SenderNetIDBin),
                                        case pp_config:lookup_netid(SenderNetID) of
                                            {ok, #{protocol := {http, Endpoint}}} ->
                                                Res = hackney:post(
                                                    Endpoint,
                                                    [],
                                                    jsx:encode(Response),
                                                    [withjbody]
                                                ),
                                                ct:print("~p :: ~p", [?MODULE, Res]);
                                            {error, routing_not_found} ->
                                                lager:error(
                                                    "received message for partner not configured: ~p",
                                                    [Decoded]
                                                )
                                        end
                                    end),
                                    {200, [], <<>>}
                            end;
                        {error, _} = Err ->
                            lager:error("dowlink handle message error ~p", [Err]),
                            {500, [], <<"An error occurred">>}
                    end
            end
    end.

handle_event(_Event, _Data, _Args) ->
    ok.

hexstring_to_int(<<"0x", Num/binary>>) ->
    erlang:binary_to_integer(Num, 16);
hexstring_to_int(Bin) ->
    throw({invalid_hexstring_bin, Bin}).

%% State Channel =====================================================

-spec init_ets() -> ok.
init_ets() ->
    ?SC_HANDLER_ETS = ets:new(?SC_HANDLER_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ok.

-spec insert_handler(PubKeyBin :: binary(), SCPid :: pid()) -> ok.
insert_handler(PubKeyBin, SCPid) ->
    true = ets:insert(?SC_HANDLER_ETS, {PubKeyBin, SCPid}),
    ok.

-spec delete_handler(PubKeyBin :: binary()) -> ok.
delete_handler(PubKeyBin) ->
    true = ets:delete(?SC_HANDLER_ETS, PubKeyBin),
    ok.

-spec lookup_handler(PubKeyBin :: binary()) -> {ok, SCPid :: pid()} | {error, any()}.
lookup_handler(PubKeyBin) ->
    case ets:lookup(?SC_HANDLER_ETS, PubKeyBin) of
        [{_, SCPid}] -> {ok, SCPid};
        [] -> {error, {not_found, PubKeyBin}}
    end.
