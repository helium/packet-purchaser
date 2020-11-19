-module(packet_purchaser_connector_udp).

-behavior(gen_server).

-include("packet_purchaser.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    pool_spec/0,
    send/1
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

-record(state, {
    socket :: gen_udp:socket(),
    address :: inet:socket_address() | inet:hostname(),
    port :: inet:port_number()
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

-spec send(binary()) -> ok | {error, any()}.
send(Data) ->
    poolboy:transaction(?POOL, fun(Worker) ->
        gen_server:call(Worker, {send, Data})
    end).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    Address = proplists:get_value(address, Args, ?DEFAULT_ADDRESS),
    Port = proplists:get_value(port, Args, ?DEFAULT_ADDRESS),
    {ok, Socket} = gen_udp:open(0, [binary, {active, true}]),
    {ok, #state{socket = Socket, address = Address, port = Port}}.

handle_call({send, Data}, _From, #state{socket = Socket, address = Address, port = Port} = State) ->
    Reply = gen_udp:send(Socket, Address, Port, Data),
    lager:info("sent ~p to ~p:~p replied: ~p", [Data, Address, Port, Reply]),
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

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

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
