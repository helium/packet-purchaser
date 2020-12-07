-module(packet_purchaser_connector_udp).

-behavior(gen_server).

-include("packet_purchaser.hrl").
-include("semtech_udp.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    pool_spec/0,
    push_data/2
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(POOL, packet_purchaser_connector_udp_pool).
-define(DEFAULT_ADDRESS, {127, 0, 0, 1}).
-define(DEFAULT_PORT, 1680).
-define(DEFAULT_SIZE, 1).
-define(DEFAULT_MAX_OVERFLOW, 0).

-define(PUSH_DATA_TICK, push_data_tick).
-define(PUSH_DATA_TIMER, timer:seconds(2)).

-define(PULL_DATA_TICK, pull_data_tick).
-define(PULL_DATA_TIMEOUT_TICK, pull_data_timeout_tick).
-define(PULL_DATA_TIMER, timer:seconds(10)).

-record(state, {
    socket :: gen_udp:socket(),
    address :: inet:socket_address() | inet:hostname(),
    port :: inet:port_number(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    pull_data :: {reference(), binary()} | undefined
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

pool_spec() ->
    Args = application:get_env(?APP, ?SERVER, []),
    poolboy:child_spec(
        ?POOL,
        [
            {name, {local, ?POOL}},
            {worker_module, ?SERVER},
            {size, proplists:get_value(size, Args, ?DEFAULT_SIZE)},
            {max_overflow, proplists:get_value(max_overflow, Args, ?DEFAULT_MAX_OVERFLOW)}
        ],
        [
            {address, proplists:get_value(address, Args, ?DEFAULT_ADDRESS)},
            {port, proplists:get_value(port, Args, ?DEFAULT_PORT)}
        ]
    ).

-spec push_data(binary(), binary()) -> ok | {error, any()}.
push_data(Token, Data) ->
    poolboy:transaction(?POOL, fun(Worker) ->
        gen_server:call(Worker, {push_data, Token, Data})
    end).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    Address = proplists:get_value(address, Args, ?DEFAULT_ADDRESS),
    Port = proplists:get_value(port, Args, ?DEFAULT_PORT),
    {ok, Socket} = gen_udp:open(0, [binary, {active, true}]),
    _ = schedule_pull_data(),
    {ok, #state{socket = Socket, address = Address, port = Port}}.

handle_call(
    {push_data, Token, Data},
    _From,
    #state{push_data = PushData} = State
) ->
    {Reply, TimerRef} = send_push_data(Token, Data, State),
    {reply, Reply, State#state{push_data = maps:put(Token, {Data, TimerRef}, PushData)}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {udp, Socket, Address, Port, Data},
    #state{
        socket = Socket,
        address = Address,
        port = Port,
        push_data = PushData,
        pull_data = PullData
    } = State
) ->
    case semtech_udp:identifier(Data) of
        ?PUSH_ACK ->
            Token = semtech_udp:token(Data),
            case maps:get(Token, PushData, undefined) of
                undefined ->
                    lager:debug("got unkown push ack ~p", [Token]),
                    {noreply, State};
                {_, TimerRef} ->
                    lager:debug("got push ack ~p", [Token]),
                    _ = erlang:cancel_timer(TimerRef),
                    {noreply, State#state{push_data = maps:remove(Token, PushData)}}
            end;
        ?PULL_ACK ->
            {PullDataRef, PullDataToken} = PullData,
            case semtech_udp:token(Data) of
                PullDataToken ->
                    erlang:cancel_timer(PullDataRef),
                    lager:debug("got pull ack for ~p", [PullDataToken]),
                    _ = schedule_pull_data(),
                    {noreply, State#state{pull_data = undefined}};
                _UnknownToken ->
                    lager:warning("got unknown pull ack for ~p", [_UnknownToken]),
                    {noreply, State}
            end;
        _ ->
            {noreply, State}
    end;
handle_info(
    {?PUSH_DATA_TICK, Token},
    #state{push_data = PushData} = State
) ->
    case maps:get(Token, PushData, undefined) of
        undefined ->
            lager:debug("got unkown push data timeout ~p", [Token]),
            {noreply, State};
        {Data, _} ->
            lager:debug("got push data timeout ~p, retrying", [Token]),
            {_Reply, TimerRef} = send_push_data(Token, Data, State),
            {noreply, State#state{push_data = maps:put(Token, {Data, TimerRef}, PushData)}}
    end;
handle_info(
    ?PULL_DATA_TICK,
    State
) ->
    {ok, RefAndToken} = send_pull_data(State),
    {noreply, State#state{pull_data = RefAndToken}};
handle_info(
    ?PULL_DATA_TIMEOUT_TICK,
    #state{socket = Socket} = State
) ->
    lager:error("got a pull data timeout closing down"),
    ok = gen_udp:close(Socket),
    {stop, pull_data_timeout, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{socket = Socket}) ->
    ok = gen_udp:close(Socket),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec schedule_pull_data() -> reference().
schedule_pull_data() ->
    _ = erlang:send_after(?PULL_DATA_TIMER, self(), ?PULL_DATA_TICK).

-spec send_pull_data(#state{}) -> {ok, {reference(), binary()}} | {error, any()}.
send_pull_data(
    #state{socket = Socket, address = Address, port = Port}
) ->
    Token = semtech_udp:token(),
    % TODO: get MAC from local chain pub key
    Data = semtech_udp:pull_data(Token, <<1, 2, 3, 4, 5, 6, 7, 8>>),
    case gen_udp:send(Socket, Address, Port, Data) of
        ok ->
            lager:debug("sent pull data keepalive ~p", [Token]),
            TimerRef = erlang:send_after(?PULL_DATA_TIMER, self(), ?PULL_DATA_TIMEOUT_TICK),
            {ok, {TimerRef, Token}};
        Error ->
            lager:debug("failed to send pull data keepalive ~p: ~p", [Token, Error]),
            Error
    end.

-spec send_push_data(binary(), binary(), #state{}) -> {ok | {error, any()}, reference()}.
send_push_data(
    Token,
    Data,
    #state{socket = Socket, address = Address, port = Port}
) ->
    Reply = gen_udp:send(Socket, Address, Port, Data),
    TimerRef = erlang:send_after(?PUSH_DATA_TIMER, self(), {?PUSH_DATA_TICK, Token}),
    lager:debug("sent ~p/~p to ~p:~p replied: ~p", [Token, Data, Address, Port, Reply]),
    {Reply, TimerRef}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
