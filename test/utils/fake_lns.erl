-module(fake_lns).

-behavior(gen_server).

-include("semtech_udp.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    delay_next_udp/2,
    rcv/2, rcv/3
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

-record(state, {
    socket :: gen_udp:socket(),
    port :: inet:port_number(),
    forward :: pid(),
    delay_next_udp = 0 :: integer()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

delay_next_udp(Pid, Delay) ->
    gen_server:cast(Pid, {delay_next_udp, Delay}).

rcv(Pid, Type) ->
    rcv(Pid, Type, timer:seconds(1)).

rcv(Pid, Type, Delay) ->
    receive
        {?MODULE, Pid, Type, Data} -> {ok, Data}
    after Delay -> ct:fail("fake_lns rcv timeout")
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    Port = maps:get(port, Args),
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}]),
    Pid = maps:get(forward, Args),
    {ok, #state{socket = Socket, port = Port, forward = Pid}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({delay_next_udp, Delay}, State) ->
    lager:info("delaying next udp by ~p", [Delay]),
    {noreply, State#state{delay_next_udp = Delay}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {udp, Socket, IP, Port, Packet},
    #state{socket = Socket} = State
) ->
    ok = handle_udp(IP, Port, Packet, State),
    {noreply, State#state{delay_next_udp = 0}};
handle_info(
    {send, IP, Port, Type, Map, Data},
    #state{socket = Socket, forward = Pid} = State
) ->
    lager:info("sending ~p: ~p / ~p", [Type, Map, Data]),
    Pid ! {?MODULE, self(), Type, Map},
    _ = gen_udp:send(Socket, IP, Port, Data),
    {noreply, State};
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

handle_udp(
    IP,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, _MAC:8/binary,
        BinJSX/binary>>,
    #state{delay_next_udp = Delay} = _State
) ->
    lager:info("got PUSH_DATA: ~p, delaying: ~p", [Token, Delay]),
    Map = jsx:decode(BinJSX),
    erlang:send_after(
        Delay,
        self(),
        {send, IP, Port, ?PUSH_DATA, Map, semtech_udp:push_ack(Token)}
    ),
    ok;
handle_udp(
    IP,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, MAC:8/binary>>,
    #state{delay_next_udp = Delay} = _State
) ->
    lager:info("got PULL_DATA: ~p, delaying: ~p", [Token, Delay]),
    erlang:send_after(
        Delay,
        self(),
        {send, IP, Port, ?PULL_DATA, {Token, MAC}, semtech_udp:pull_ack(Token)}
    ),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
