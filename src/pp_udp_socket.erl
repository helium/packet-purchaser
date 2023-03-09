-module(pp_udp_socket).

-export([
    open/2,
    close/1,
    update_address/2,
    get_address/1
]).

-export([send/2]).

-record(socket, {
    socket :: gen_udp:socket(),
    primary :: socket_info(),
    tee :: undefined | socket_info()
}).

-type socket() :: #socket{}.
-type socket_address() :: inet:socket_address() | inet:hostname().
-type socket_port() :: inet:port_number().
-type socket_info() :: {socket_address(), socket_port()}.

-export_type([socket/0, socket_address/0, socket_port/0, socket_info/0]).

-spec open(socket_info(), socket_info()) -> {ok, socket()}.
open(Primary, Tee) ->
    {ok, Socket} = gen_udp:open(0, [binary, {active, true}]),
    {ok, #socket{socket = Socket, primary = Primary, tee = Tee}}.

-spec send(socket(), binary()) -> ok | {error, any()}.
send(#socket{socket = Socket, primary = Primary, tee = Tee}, Data) ->
    Reply = do_send(Socket, Primary, Data),
    _ = do_send(Socket, Tee, Data),
    Reply.

-spec do_send(gen_udp:socket(), undefined | socket_info(), binary()) -> ok | {error, any()}.
do_send(_Socket, undefined, _Data) -> ok;
do_send(Socket, {Address, Port}, Data) -> gen_udp:send(Socket, Address, Port, Data).

close(#socket{socket = Socket}) ->
    gen_udp:close(Socket).

-spec update_address(socket(), socket_info()) -> {ok, socket()}.
update_address(#socket{} = Socket, SocketInfo) ->
    {ok, Socket#socket{primary = SocketInfo}}.

-spec get_address(socket()) -> socket_info().
get_address(#socket{primary = Primary}) ->
    Primary.
