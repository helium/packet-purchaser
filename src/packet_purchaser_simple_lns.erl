-module(packet_purchaser_simple_lns).

-behavior(gen_server).

-include("semtech_udp.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
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
    port :: inet:port_number()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{port := Port} = _Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, _Args]),
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}]),
    {ok, #state{socket = Socket, port = Port}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {udp, Socket, IP, Port, Packet},
    #state{socket = Socket} = State
) ->
    ok = handle_udp(IP, Port, Packet, State),
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
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>,
    #state{socket = Socket} = _State
) ->
    lager:info("got PUSH_DATA: ~p ~p from ~p", [Token, jsx:decode(BinJSX), MAC]),
    _ = gen_udp:send(Socket, IP, Port, semtech_udp:push_ack(Token)),
    ok;
handle_udp(
    IP,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, MAC:8/binary>>,
    #state{socket = Socket} = _State
) ->
    lager:info("got PULL_DATA: ~p from ~p", [Token, MAC]),
    _ = gen_udp:send(Socket, IP, Port, semtech_udp:pull_ack(Token)),
    ok;
handle_udp(
    _IP,
    _Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?TX_ACK:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>,
    _State
) ->
    lager:info("got TX_ACK: ~p ~p from ~p", [Token, jsx:decode(BinJSX), MAC]),
    ok.
