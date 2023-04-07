-module(pp_roaming_downlink).

-include_lib("elli/include/elli.hrl").
-include("config.hrl").

-behaviour(elli_handler).

%% Downlink API
-export([
    handle/2,
    handle_event/3
]).

%% State Channel API
-export([
    insert_handler/2,
    lookup_handler/1
]).

-define(SC_HANDLER_ETS, pp_http_sc_handler_ets).

%% Downlink Handler ==================================================

handle(Req, Args) ->
    Method = elli_request:method(Req),
    Host = elli_request:get_header(<<"Host">>, Req),
    lager:info("request from [host: ~p]", [Host]),

    lager:debug("request: ~p", [{Method, elli_request:path(Req), Req, Args}]),
    Body = elli_request:body(Req),
    Decoded = jsx:decode(Body),

    case pp_roaming_protocol:handle_message(Decoded) of
        ok ->
            {200, [], <<"OK">>};
        {error, _} = Err ->
            lager:error("dowlink handle message error ~p", [Err]),
            {500, [], <<"An error occurred">>};
        {join_accept, {SCPid, PubKeyBin, SCResp}} ->
            lager:debug("sending downlink [sc_pid: ~p]", [SCPid]),
            catch SCPid ! {send_response, PubKeyBin, SCResp},
            {200, [], <<"downlink sent: 1">>};
        {downlink, Response, {SCPid, PubKeyBin, SCResp}, {Endpoint, FlowType}} ->
            lager:debug(
                "sending downlink [sc_pid: ~p] [response: ~p]",
                [SCPid, Response]
            ),
            catch SCPid ! {send_response, PubKeyBin, SCResp},
            case FlowType of
                sync ->
                    {200, [], jsx:encode(Response)};
                async ->
                    spawn(fun() ->
                        Res = hackney:post(Endpoint, [], jsx:encode(Response), [with_body]),
                        lager:debug("async downlink repsonse ~p", [?MODULE, Res])
                    end),
                    {200, [], <<"downlink sent: 2">>}
            end
    end.

handle_event(Event, _Data, _Args) ->
    case
        lists:member(Event, [
            bad_request,
            %% chunk_complete,
            %% client_closed,
            %% client_timeout,
            %% file_error,
            invalid_return,
            %% request_closed,
            %% request_complete,
            request_error,
            request_exit,
            request_parse_error,
            request_throw
            %% elli_startup
        ])
    of
        true -> lager:error("~p ~p ~p", [Event, _Data, _Args]);
        false -> lager:debug("~p ~p ~p", [Event, _Data, _Args])
    end,

    ok.

%% State Channel =====================================================

-spec insert_handler(PubKeyBin :: libp2p_crypto:pubkey_bin(), SCPid :: pid()) -> ok.
insert_handler(PubKeyBin, SCPid) ->
    pg:join(PubKeyBin, SCPid),
    ok.

-spec lookup_handler(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, SCPid :: pid()} | {error, any()}.
lookup_handler(PubKeyBin) ->
    case pg:get_members(PubKeyBin) of
        [] ->
            {error, {not_found, PubKeyBin}};
        [Pid | _] ->
            {ok, Pid}
    end.
