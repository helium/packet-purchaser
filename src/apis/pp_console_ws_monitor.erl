%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser Console WS Monitor ==
%%
%% - Restarts websocket connection if it goes down
%%
%% @end
%%%-------------------------------------------------------------------
-module(pp_console_ws_monitor).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    start_ws_connection/0
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

-define(BACKOFF_MIN, timer:seconds(10)).
-define(BACKOFF_MAX, timer:minutes(5)).
-define(START_WS_CONNECTION, start_ws_connection).

-record(state, {
    auto_connect :: boolean(),
    backoff :: backoff:backoff(),
    backoff_timer :: undefined | reference()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

start_ws_connection() ->
    ?MODULE ! ?START_WS_CONNECTION.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    ct:print("~p init with ~p", [?SERVER, Args]),
    lager:info("~p init with ~p", [?SERVER, Args]),
    AutoConnect =
        case maps:get(auto_connect, Args, false) of
            "true" -> true;
            true -> true;
            _ -> false
        end,
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    {ok,
        #state{
            auto_connect = AutoConnect,
            backoff = Backoff
        },
        {continue, ?START_WS_CONNECTION}}.

handle_continue(?START_WS_CONNECTION, #state{auto_connect = true} = State) ->
    lager:info("auto connecting websocket"),
    ?MODULE:start_ws_connection(),
    {noreply, State};
handle_continue(?START_WS_CONNECTION, #state{auto_connect = false} = State) ->
    {noreply, State};
handle_continue(_Msg, State) ->
    lager:warning("rcvd unknown continue msg: ~p", [_Msg]),
    {noreply, State}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?START_WS_CONNECTION, State0) ->
    State1 =
        case pp_console_ws_worker:start_ws() of
            {ok, _} ->
                _ = pp_console_ws_worker:activate(),
                backoff_success(State0);
            {error, Reason, Err} ->
                lager:warning(
                    "could not start websocket connection: [reason: ~p] [error: ~p]",
                    [Reason, Err]
                ),
                backoff_failure(State0)
        end,
    {noreply, State1};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ct:print("went down ~p : ~p", [?MODULE, _Reason]),
    ok.

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
        backoff_timer = erlang:send_after(Delay, self(), ?START_WS_CONNECTION)
    }.
