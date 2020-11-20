-module(fake_lns).

-behavior(gen_server).

-include("lorawan_gwmp.hrl").

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
    port :: inet:port_number(),
    forward :: pid()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

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

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({udp, Socket, IP, Port, Packet}, #state{socket = Socket} = State) ->
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
    Address,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned,
        _MAC:64/integer, BinJSX/binary>>,
    #state{socket = Socket, forward = Pid} = _State
) ->
    Map = jsx:decode(BinJSX),
    Pid ! {fake_lns, self(), ?PUSH_DATA, Map},
    gen_udp:send(Socket, Address, Port, lorawan_gwmp:push_ack(Token)).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
