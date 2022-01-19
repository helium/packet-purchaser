-module(pp_pull_resp).

-behavior(gen_server).

-include("semtech_udp.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    get_port/1,
    insert_sc_pid/2,
    delete_sc_pid/1,
    init_ets/0
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
-define(ETS, pp_pull_resp_ets).

-record(state, {
    socket :: gen_udp:socket(),
    port :: inet:port_number()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec get_port(pid()) -> inet:port_number().
get_port(Pid) ->
    gen_server:call(Pid, get_port).

-spec insert_sc_pid(MAC :: binary(), SCPid :: pid()) -> ok.
insert_sc_pid(MAC, SCPid) ->
    true = ets:insert(?ETS, {MAC, SCPid}),
    ok.

-spec delete_sc_pid(MAC :: binary()) -> ok.
delete_sc_pid(MAC) ->
    true = ets:delete(?ETS, MAC),
    ok.

-spec get_sc_pid_for_mac(MAC :: binary()) -> {ok, pid()} | {error, not_found}.
get_sc_pid_for_mac(MAC) ->
    case ets:lookup(?ETS, MAC) of
        [{MAC, SCPid}] ->
            case erlang:is_process_alive(SCPid) of
                true -> {ok, SCPid};
                false -> {error, not_found}
            end;
        [] ->
            {error, not_found}
    end.

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    Port = maps:get(port, Args),
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}]),

    ct:print("started singleton ~p on ~p", [Socket, Port]),
    {ok, #state{socket = Socket, port = Port}}.

handle_call(get_port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({udp, Socket, FromAddress, FromPort, Data}, #state{socket = Socket} = State) ->
    ct:print("[~p:~p] got udp packet ~p", [FromAddress, FromPort, Data]),

    case semtech_udp:identifier(Data) of
        ?PULL_RESP ->
            ok = handle_pull_resp(Data, Socket, FromAddress, FromPort);
        ID ->
            ID1 = semtech_udp:identifier_to_atom(ID),
            ct:print("We don't handle (~p:~p)", [ID, ID1]),
            throw(ID)
    end,

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

-spec handle_pull_resp(
    Data :: binary(),
    Socket :: gen_udp:socket(),
    Address :: inet:socket_address(),
    Port :: inet:port_number()
) -> ok.
handle_pull_resp(Data, Socket, Address, Port) ->
    {ok, Token, MAC, BinData} = semtech_udp:pull_resp_to_mac_data(Data),
    ok = queue_downlink(MAC, BinData),
    ok = send_tx_ack(Socket, Address, Port, Token, MAC),
    ok.

queue_downlink(MAC, BinData) ->
    Map = maps:get(<<"txpk">>, BinData),
    {ok, SCPid} = get_sc_pid_for_mac(MAC),

    JSONData0 = maps:get(<<"data">>, Map),
    JSONData1 =
        try
            base64:decode(JSONData0)
        catch
            _:_ ->
                lager:warning("failed to decode pull_resp data ~p", [JSONData0]),
                JSONData0
        end,

    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        JSONData1,
        maps:get(<<"powe">>, Map),
        maps:get(<<"tmst">>, Map),
        maps:get(<<"freq">>, Map),
        erlang:binary_to_list(maps:get(<<"datr">>, Map))
    ),

    catch blockchain_state_channel_common:send_response(
        SCPid,
        blockchain_state_channel_response_v1:new(true, DownlinkPacket)
    ),
    ok.

send_tx_ack(Socket, Address, Port, Token, MAC) ->
    OutData = semtech_udp:tx_ack(Token, MAC),
    gen_udp:send(Socket, Address, Port, OutData),
    ok.
