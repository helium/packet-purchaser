-module(console_callback).

-behavior(elli_handler).
-behavior(elli_websocket_handler).

-export([
    init/2,
    handle/2,
    handle_event/3
]).

-export([
    websocket_init/2,
    websocket_handle/3,
    websocket_info/3,
    websocket_handle_event/3
]).

-export([update_config/2]).

-define(UPDATE_CONFIG, update_config).

-spec update_config(pid(), list(map())) -> ok.
update_config(WSPid, Config) ->
    WSPid ! {?UPDATE_CONFIG, Config},
    ok.

init(Req, Args) ->
    case elli_request:get_header(<<"Upgrade">>, Req) of
        <<"websocket">> ->
            init_ws(elli_request:path(Req), Req, Args);
        _ ->
            ignore
    end.

websocket_init(Req, Opts) ->
    lager:debug("websocket_init ~p~n~p", [Req, Opts]),
    maps:get(forward, Opts) ! {websocket_init, self()},
    {ok, [], Opts}.

init_ws([<<"websocket">>], _Req, _Args) ->
    {ok, handover};
init_ws(_One, _Two, _Three) ->
    lager:warning("Unhandled init_ws message: ~n~p~n~p~n~p", [_One, _Two, _Three]),
    ignore.

handle(Req, _Args) ->
    Method =
        case elli_request:get_header(<<"Upgrade">>, Req) of
            <<"websocket">> ->
                websocket;
            _ ->
                elli_request:method(Req)
        end,
    handle(Method, elli_request:path(Req), Req, _Args).

handle_event(_Event, _Data, _Args) ->
    ok.

websocket_handle(_Req, {text, Msg}, State) ->
    {ok, Map} = pp_console_ws_handler:decode_msg(Msg),
    handle_message(Map, State);
websocket_handle(_Req, _Frame, State) ->
    lager:warning("websocket_handle ~p", [_Frame]),
    {ok, State}.

websocket_info(_Req, {?UPDATE_CONFIG, Map}, State) ->
    Data = pp_console_ws_handler:encode_msg(
        <<"0">>,
        <<"organization:all">>,
        <<"organization:all:update">>,
        Map
    ),
    {reply, {text, Data}, State};
websocket_info(_Req, _Msg, State) ->
    lager:warning("websocket_info ~p", [_Msg]),
    {ok, State}.

websocket_handle_event(_Event, _Args, _State) ->
    lager:warning("websocket_handle_event ~p~n~p~n~p", [_Event, _Args, _State]),
    ok.

handle(websocket, [<<"websocket">>], Req, Args) ->
    %% Upgrade to a websocket connection.
    elli_websocket:upgrade(Req, [
        {handler, ?MODULE},
        {handler_opts, Args}
    ]),
    %% websocket is closed:
    %% See RFC-6455 (https://tools.ietf.org/html/rfc6455) for a list of
    %% valid WS status codes than can be used on a close frame.
    %% Note that the second element is the reason and is abitrary but should be meaningful
    %% in regards to your server and sub-protocol.
    {<<"1000">>, <<"Closed">>};
handle(_Method, _Path, _Req, _Args) ->
    lager:warning("got unknown~p req on ~p args=~p", [_Method, _Path, _Args]),
    {404, [], <<"Not Found">>}.

handle_message(#{ref := Ref, topic := <<"phoenix">>, event := <<"heartbeat">>}, State) ->
    Data = pp_console_ws_handler:encode_msg(Ref, <<"phoenix">>, <<"phx_reply">>, #{
        <<"status">> => <<"ok">>
    }),
    {reply, {text, Data}, State};
handle_message(
    #{event := <<"packet">>, topic := <<"roaming">>, payload := Payload} = Message,
    State
) ->
    lager:info("ws handling message: ~p", [Message]),
    Pid = maps:get(forward, State),
    Pid ! {websocket_packet, Payload},
    {ok, State};
handle_message(Map, State) ->
    lager:warning("got unhandle message ~p ~p", [Map, lager:pr(State, ?MODULE)]),
    Pid = maps:get(forward, State),
    Pid ! {websocket_msg, Map},
    {ok, State}.
