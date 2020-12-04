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

-define(PUSH_DATA_TIMEOUT, push_data_timeout).
-define(PUSH_DATA_TIMER, timer:seconds(2)).

-record(state, {
    socket :: gen_udp:socket(),
    address :: inet:socket_address() | inet:hostname(),
    port :: inet:port_number(),
    push_data = #{} :: #{binary() => {binary(), reference()}}
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
            {size, 5},
            {max_overflow, 10}
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
    {ok, #state{socket = Socket, address = Address, port = Port}}.

handle_call(
    {push_data, Token, Data},
    _From,
    State0
) ->
    {Reply, State1} = send_push_data(Token, Data, State0),
    {reply, Reply, State1};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {udp, Socket, Address, Port, Data},
    #state{socket = Socket, address = Address, port = Port, push_data = PushData} = State
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
        _ ->
            {noreply, State}
    end;
handle_info(
    {?PUSH_DATA_TIMEOUT, Token},
    #state{push_data = PushData} = State0
) ->
    case maps:get(Token, PushData, undefined) of
        undefined ->
            lager:debug("got unkown push data timeout ~p", [Token]),
            {noreply, State0};
        {Data, _} ->
            lager:debug("got push data timeout ~p, retrying", [Token]),
            {_Reply, State1} = send_push_data(Token, Data, State0),
            {noreply, State1}
    end;
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

-spec send_push_data(binary(), binary(), #state{}) -> {ok | {error, any()}, #state{}}.
send_push_data(
    Token,
    Data,
    #state{socket = Socket, address = Address, port = Port, push_data = PushData} = State
) ->
    Reply = gen_udp:send(Socket, Address, Port, Data),
    TimerRef = erlang:send_after(?PUSH_DATA_TIMER, self(), {?PUSH_DATA_TIMEOUT, Token}),
    lager:debug("sent ~p/~p to ~p:~p replied: ~p", [Token, Data, Address, Port, Reply]),
    {Reply, State#state{push_data = maps:put(Token, {Data, TimerRef}, PushData)}}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
