%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser Console WS Manager ==
%%
%% - Gets the console token with a backoff
%% - Starts websocket connection when token is received successfully
%%
%% @end
%%%-------------------------------------------------------------------
-module(pp_console_ws_manager).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    get_token/0,
    start_ws/0
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(POOL, router_console_api_pool).
-define(HEADER_JSON, {<<"Content-Type">>, <<"application/json">>}).

-define(BACKOFF_MIN, timer:seconds(2)).
-define(BACKOFF_MAX, timer:minutes(1)).

-define(GET_TOKEN, get_token).
-define(START_WS_CONNECTION, start_ws_connection).

-record(state, {
    ws = undefined :: undefined | pid(),
    http_endpoint :: binary(),
    secret :: binary(),
    ws_endpoint :: binary(),
    token = undefined :: undefined | binary(),
    backoff :: backoff:backoff(),
    backoff_timer :: undefined | reference()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec get_token() -> ok.
get_token() ->
    gen_server:call(?MODULE, ?GET_TOKEN).

-spec start_ws() -> {ok, pid()} | {error, any()}.
start_ws() ->
    gen_server:call(?MODULE, ?START_WS_CONNECTION).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    WSEndpoint = maps:get(ws_endpoint, Args),
    Endpoint = maps:get(endpoint, Args),
    Secret = maps:get(secret, Args),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    State = #state{
        http_endpoint = Endpoint,
        secret = Secret,
        ws_endpoint = WSEndpoint,
        backoff = Backoff
    },
    AutoConnect =
        case maps:get(auto_connect, Args, false) of
            "true" -> true;
            V -> V
        end,
    case AutoConnect of
        true ->
            {ok, State, {continue, ?GET_TOKEN}};
        _ ->
            {ok, State}
    end.

handle_continue(?GET_TOKEN, State0) ->
    %% For use during initialization.
    case get_token(State0) of
        {State1, Continue} -> {noreply, State1, Continue};
        State1 -> {noreply, State1}
    end;
handle_continue(?START_WS_CONNECTION, State0) ->
    State1 = start_ws(State0),
    {noreply, State1}.

handle_call(?GET_TOKEN, _From, State0) ->
    %% For manual use.
    case get_token(State0) of
        {State1, Continue} -> {noreply, State1, Continue};
        State1 -> {noreply, State1}
    end;
handle_call(?START_WS_CONNECTION, _From, State0) ->
    State1 = start_ws(State0),
    {noreply, State1};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?GET_TOKEN, State0) ->
    %% For backoff use.
    case get_token(State0) of
        {State1, Continue} -> {noreply, State1, Continue};
        State1 -> {noreply, State1}
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ct:print("went down ~p : ~p", [?MODULE, _Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal State Function Definitions
%% ------------------------------------------------------------------
-spec get_token(#state{}) -> {#state{}, {continue, atom()}} | #state{}.
get_token(#state{http_endpoint = Endpoint, secret = Secret} = State) ->
    case get_token(Endpoint, Secret) of
        {ok, Token} ->
            lager:info("console token success"),
            {backoff_success(State#state{token = Token}), {continue, ?START_WS_CONNECTION}};
        {error, _} ->
            lager:warning("console token failed"),
            backoff_failure(State)
    end.

-spec start_ws(#state{}) -> #state{}.
start_ws(#state{ws_endpoint = WSEndpoint, token = Token} = State) ->
    case start_ws(WSEndpoint, Token) of
        {ok, Pid} ->
            lager:info("console websocket success"),
            ok = pp_console_ws_worker:ws_update_pid(Pid),
            State#state{ws = Pid};
        _ ->
            lager:warning("console websocket failed"),
            backoff_failure(State)
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

backoff_success(#state{backoff = Backoff0, backoff_timer = Timer} = State) ->
    _ = (catch erlang:cancel_timer(Timer)),
    {_, Backoff1} = backoff:succeed(Backoff0),
    State#state{
        backoff = Backoff1,
        backoff_timer = undefined
    }.

backoff_failure(#state{backoff = Backoff0, backoff_timer = Timer} = State) ->
    _ = (catch erlang:cancel_timer(Timer)),
    {Delay, Backoff1} = backoff:fail(Backoff0),
    State#state{
        backoff = Backoff1,
        backoff_timer = erlang:send_after(Delay, self(), ?GET_TOKEN)
    }.

-spec get_token(Endpoint :: binary(), Secret :: binary()) -> {ok, binary()} | {error, any()}.
get_token(Endpoint, Secret) ->
    case
        hackney:post(
            <<Endpoint/binary, "/api/packet_purchaser/sessions">>,
            [?HEADER_JSON],
            jsx:encode(#{secret => Secret}),
            [with_body, {pool, ?POOL}]
        )
    of
        {ok, 201, _Headers, Body} ->
            #{<<"jwt">> := Token} = jsx:decode(Body, [return_maps]),
            {ok, Token};
        _Other ->
            {error, _Other}
    end.

-spec start_ws(WSEndpoint :: binary(), Token :: binary()) -> {ok, pid()} | {error, any()}.
start_ws(WSEndpoint, Token) ->
    Url = binary_to_list(<<WSEndpoint/binary, "?token=", Token/binary, "&vsn=2.0.0">>),
    Args = #{
        url => Url,
        auto_join => pp_console_ws_worker:ws_get_auto_join_topics(),
        forward => self()
    },
    pp_console_ws_client:start_link(Args).
