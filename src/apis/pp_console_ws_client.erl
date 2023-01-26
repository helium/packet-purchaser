%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser Console WS Client ==
%%
%% - Encoding/Decoding messages to/from Roaming Console
%% - Websocket health
%% - Joining topics
%% - Forwarding WS messages to the ws_worker
%%
%% @end
%%%-------------------------------------------------------------------
-module(pp_console_ws_client).

-behaviour(websocket_client).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    encode_msg/3, encode_msg/4, encode_msg/5,
    decode_msg/1
]).

%% ------------------------------------------------------------------
%% websocket_client Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    onconnect/2,
    ondisconnect/2,
    websocket_handle/3,
    websocket_info/3,
    websocket_terminate/3
]).

-define(HEARTBEAT_TIMER, timer:seconds(30)).
-define(HEARTBEAT_REF, <<"BPM_">>).
-define(TOPIC_PHX, <<"phoenix">>).
-define(EVENT_JOIN, <<"phx_join">>).

-record(state, {
    heartbeat = 0 :: non_neg_integer(),
    heartbeat_timeout :: undefined | reference(),
    auto_join = [] :: [binary()],
    forward :: pid()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
-spec start_link(map()) -> {ok, pid()} | {error, any()}.
start_link(Args) ->
    Url = maps:get(url, Args),
    websocket_client:start_link(Url, ?MODULE, maps:to_list(Args)).

-spec encode_msg(binary(), binary(), binary()) -> binary().
encode_msg(Ref, Topic, Event) ->
    encode_msg(Ref, Topic, Event, #{}).

-spec encode_msg(binary(), binary(), binary(), map()) -> binary().
encode_msg(Ref, Topic, Event, Payload) ->
    encode_msg(Ref, Topic, Event, Payload, <<"0">>).

-spec encode_msg(binary(), binary(), binary(), map(), binary()) -> binary().
encode_msg(Ref, Topic, Event, Payload, JRef) ->
    jsx:encode([JRef, Ref, Topic, Event, Payload]).

-spec decode_msg(binary()) -> {ok, map()} | {error, any()}.
decode_msg(Msg) ->
    try jsx:decode(Msg, [return_maps]) of
        [JRef, Ref, Topic, Event, Payload | _] ->
            {ok, #{
                ref => Ref,
                jref => JRef,
                topic => Topic,
                event => Event,
                payload => Payload
            }}
    catch
        _:_ -> {error, "decode_failed"}
    end.

%% ------------------------------------------------------------------
%% websocket_client Function Definitions
%% ------------------------------------------------------------------
init(ArgsList) ->
    Args = maps:from_list(ArgsList),
    lager:info("~p init with ~p", [?MODULE, Args]),
    AutoJoin = maps:get(auto_join, Args, []),
    Pid = maps:get(forward, Args),
    {once, #state{auto_join = AutoJoin, forward = Pid}}.

onconnect(_WSReq, State) ->
    lager:debug("connected ~p", [_WSReq]),
    self() ! heartbeat,
    self() ! auto_join,
    pp_metrics:ws_state(true),
    {ok, State}.

ondisconnect(Error, State) ->
    lager:warning("discconnected ~p", [Error]),
    pp_metrics:ws_state(false),
    {close, Error, State}.

websocket_handle({text, Msg}, _Req, State) ->
    case ?MODULE:decode_msg(Msg) of
        {ok, Decoded} ->
            handle_message(Decoded, State);
        {error, _Reason} ->
            lager:error("failed to decode message: ~p ~p", [Msg, _Req])
    end;
websocket_handle(_Msg, _Req, State) ->
    lager:warning("rcvd unknown websocket_handle msg: ~p, ~p", [_Msg, _Req]),
    {ok, State}.

websocket_info(heartbeat, _Req, #state{heartbeat = Heartbeat} = State) ->
    Ref = <<?HEARTBEAT_REF/binary, (erlang:integer_to_binary(Heartbeat))/binary>>,
    Payload = ?MODULE:encode_msg(Ref, ?TOPIC_PHX, <<"heartbeat">>),
    lager:debug("sending heartbeat ~p", [Ref]),
    _ = erlang:send_after(?HEARTBEAT_TIMER, self(), heartbeat),
    TimerRef = erlang:send_after(?HEARTBEAT_TIMER, self(), {heartbeat_timeout, Ref}),
    pp_metrics:ws_state(true),
    {reply, {text, Payload}, State#state{heartbeat = Heartbeat + 1, heartbeat_timeout = TimerRef}};
websocket_info({heartbeat_timeout, Ref}, _Req, State) ->
    lager:warning("we missed heartbeat ~p", [Ref]),
    {ok, State#state{heartbeat = 0, heartbeat_timeout = undefined}};
websocket_info(auto_join, _Req, #state{auto_join = AutoJoin} = State) ->
    lists:foreach(
        fun(Topic) ->
            Ref = <<"REF_", Topic/binary>>,
            Payload = ?MODULE:encode_msg(Ref, Topic, ?EVENT_JOIN, #{}),
            websocket_client:cast(self(), {text, Payload}),
            lager:debug("joining ~p with refs ~p", [Topic, Ref])
        end,
        AutoJoin
    ),
    lager:debug("joined"),
    ok = pp_console_ws_worker:ws_joined(),
    {ok, State};
websocket_info(close, _Req, State) ->
    lager:info("rcvd close msg"),
    pp_metrics:ws_state(false),
    {close, <<>>, State};
websocket_info({ws_resp, Payload}, _Req, State) ->
    {reply, {text, Payload}, State};
websocket_info(_Msg, _Req, State) ->
    lager:warning("rcvd unknown websocket_info msg: ~p, ~p", [_Msg, _Req]),
    {ok, State}.

websocket_terminate(Reason, _ConnState, _State) ->
    lager:warning("websocket closed wih reason ~p", [Reason]),
    pp_metrics:ws_state(false),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle_message(
    #{
        ref := <<"BPM_", Heartbeat/binary>>,
        topic := <<"phoenix">>,
        event := <<"phx_reply">>,
        payload := Payload
    },
    #state{heartbeat_timeout = TimerRef} = State
) ->
    _ = catch erlang:cancel_timer(TimerRef),
    case maps:get(<<"status">>, Payload, undefined) of
        <<"ok">> -> lager:debug("hearbeat ~p ok", [Heartbeat]);
        _Other -> lager:warning("hearbeat ~p failed: ~p", [Heartbeat, _Other])
    end,
    {ok, State#state{heartbeat_timeout = undefined}};
handle_message(
    #{
        jref := <<"REF_", Topic/binary>>,
        topic := Topic,
        event := <<"phx_reply">>,
        payload := Payload
    },
    #state{auto_join = AutoJoin} = State
) ->
    case lists:member(Topic, AutoJoin) of
        true ->
            case maps:get(<<"status">>, Payload, undefined) of
                <<"ok">> -> lager:debug("joined ~p ok", [Topic]);
                _Other -> lager:warning("joined ~p failed: ~p", [Topic, _Other])
            end;
        false ->
            lager:warning("joined unknown topic: ~p", [Topic])
    end,
    {ok, State};
handle_message(#{topic := Topic, event := Event, payload := Payload}, #state{} = State) ->
    ok = pp_console_ws_worker:ws_handle_message(Topic, Event, Payload),
    {ok, State};
handle_message(_Msg, State) ->
    lager:debug("unhandled message ~p", [_Msg]),
    {ok, State}.
