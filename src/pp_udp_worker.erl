-module(pp_udp_worker).

-behavior(gen_server).

-include("packet_purchaser.hrl").
-include("semtech_udp.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    push_data/4
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

-define(PUSH_DATA_TICK, push_data_tick).
-define(PUSH_DATA_TIMER, timer:seconds(2)).

-define(PULL_DATA_TICK, pull_data_tick).
-define(PULL_DATA_TIMEOUT_TICK, pull_data_timeout_tick).
-define(PULL_DATA_TIMER, timer:seconds(10)).

-record(state, {
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    socket :: pp_udp_socket:socket(),
    address :: inet:socket_address() | inet:hostname(),
    port :: inet:port_number(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    sc_pid :: undefined | pid(),
    pull_data :: {reference(), binary()} | undefined,
    pull_data_timer :: non_neg_integer()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec push_data(pid(), binary(), binary(), pid()) -> ok | {error, any()}.
push_data(Pid, Token, Data, SCPid) ->
    gen_server:call(Pid, {push_data, Token, Data, SCPid}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),

    PubKeyBin = maps:get(pubkeybin, Args),
    lager:md([{gateway_id, blockchain_utils:addr2name(PubKeyBin)}]),

    Address = maps:get(address, Args),
    Port = maps:get(port, Args),
    PullDataTimer = maps:get(pull_data_timer, Args, ?PULL_DATA_TIMER),
    {ok, Socket} = pp_udp_socket:open({Address, Port}, maps:get(tee, Args, undefined)),

    %% Pull data immediately so we can establish a connection for the first
    %% pull_response.
    self() ! ?PULL_DATA_TICK,
    _ = schedule_pull_data(PullDataTimer),

    {ok, #state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        address = Address,
        port = Port,
        pull_data_timer = PullDataTimer
    }}.

handle_call(
    {push_data, Token, Data, SCPid},
    _From,
    #state{push_data = PushData} = State
) ->
    {Reply, TimerRef} = send_push_data(Token, Data, State),
    {reply, Reply, State#state{
        push_data = maps:put(Token, {Data, TimerRef}, PushData),
        sc_pid = SCPid
    }};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {udp, Socket, _Address, Port, Data},
    #state{
        socket = {socket, Socket, _, _},
        port = Port
    } = State
) ->
    lager:debug("got udp packet ~p from ~p:~p", [Data, _Address, Port]),
    try handle_udp(Data, State) of
        {noreply, _} = NoReply -> NoReply
    catch
        _E:_R ->
            lager:error("failed to handle UDP packet ~p: ~p/~p", [Data, _E, _R]),
            {noreply, State}
    end;
handle_info(
    {?PUSH_DATA_TICK, Token},
    #state{push_data = PushData} = State
) ->
    case maps:get(Token, PushData, undefined) of
        undefined ->
            {noreply, State};
        {_Data, _} ->
            lager:debug("got push data timeout ~p, ignoring lack of ack", [Token]),
            {noreply, State#state{push_data = maps:remove(Token, PushData)}}
    end;
handle_info(
    ?PULL_DATA_TICK,
    State
) ->
    {ok, RefAndToken} = send_pull_data(State),
    {noreply, State#state{pull_data = RefAndToken}};
handle_info(
    ?PULL_DATA_TIMEOUT_TICK,
    State
) ->
    lager:debug("got a pull data timeout, ignoring missed pull_ack"),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{socket = Socket}) ->
    lager:info("going down ~p", [_Reason]),
    ok = pp_udp_socket:close(Socket),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_udp(binary(), #state{}) -> {noreply, #state{}}.
handle_udp(Data, State) ->
    Identifier = semtech_udp:identifier(Data),
    lager:debug("got udp ~p / ~p", [semtech_udp:identifier_to_atom(Identifier), Data]),
    case semtech_udp:identifier(Data) of
        ?PUSH_ACK ->
            handle_push_ack(Data, State);
        ?PULL_ACK ->
            handle_pull_ack(Data, State);
        ?PULL_RESP ->
            handle_pull_resp(Data, State);
        _Id ->
            lager:warning("got unknown identifier ~p for ~p", [_Id, Data]),
            {noreply, State}
    end.

-spec handle_push_ack(binary(), #state{}) -> {noreply, #state{}}.
handle_push_ack(
    Data,
    #state{
        push_data = PushData
    } = State
) ->
    Token = semtech_udp:token(Data),
    case maps:get(Token, PushData, undefined) of
        undefined ->
            lager:debug("got unkown push ack ~p", [Token]),
            {noreply, State};
        {_, TimerRef} ->
            lager:debug("got push ack ~p", [Token]),
            _ = erlang:cancel_timer(TimerRef),
            {noreply, State#state{push_data = maps:remove(Token, PushData)}}
    end.

-spec handle_pull_ack(binary(), #state{}) -> {noreply, #state{}}.
handle_pull_ack(
    _Data,
    #state{
        pull_data = undefined
    } = State
) ->
    lager:warning("got unknown pull ack for ~p", [_Data]),
    {noreply, State};
handle_pull_ack(
    Data,
    #state{
        pull_data = {PullDataRef, PullDataToken},
        pull_data_timer = PullDataTimer
    } = State
) ->
    case semtech_udp:token(Data) of
        PullDataToken ->
            erlang:cancel_timer(PullDataRef),
            lager:debug("got pull ack for ~p", [PullDataToken]),
            _ = schedule_pull_data(PullDataTimer),
            {noreply, State#state{pull_data = undefined}};
        _UnknownToken ->
            lager:warning("got unknown pull ack for ~p", [_UnknownToken]),
            {noreply, State}
    end.

% TODO: Handle queueing downlinks
-spec handle_pull_resp(binary(), #state{}) -> {noreply, #state{}}.
handle_pull_resp(
    Data,
    #state{sc_pid = SCPid} = State
) when is_pid(SCPid) ->
    Map = maps:get(<<"txpk">>, semtech_udp:json_data(Data)),
    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        maps:get(<<"data">>, Map),
        maps:get(<<"powe">>, Map),
        maps:get(<<"tmst">>, Map),
        maps:get(<<"freq">>, Map),
        erlang:binary_to_list(maps:get(<<"datr">>, Map))
    ),
    catch blockchain_state_channel_handler:send_response(
        SCPid,
        blockchain_state_channel_response_v1:new(true, DownlinkPacket)
    ),
    Token = semtech_udp:token(Data),
    _ = send_tx_ack(Token, State),
    {noreply, State}.

-spec schedule_pull_data(non_neg_integer()) -> reference().
schedule_pull_data(PullDataTimer) ->
    _ = erlang:send_after(PullDataTimer, self(), ?PULL_DATA_TICK).

-spec send_pull_data(#state{}) -> {ok, {reference(), binary()}} | {error, any()}.
send_pull_data(
    #state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        pull_data_timer = PullDataTimer
    }
) ->
    Token = semtech_udp:token(),
    Data = semtech_udp:pull_data(Token, pp_utils:pubkeybin_to_mac(PubKeyBin)),
    case pp_udp_socket:send(Socket, Data) of
        ok ->
            lager:debug("sent pull data keepalive ~p", [Token]),
            TimerRef = erlang:send_after(PullDataTimer, self(), ?PULL_DATA_TIMEOUT_TICK),
            {ok, {TimerRef, Token}};
        Error ->
            lager:warning("failed to send pull data keepalive ~p: ~p", [Token, Error]),
            Error
    end.

-spec send_push_data(binary(), binary(), #state{}) -> {ok | {error, any()}, reference()}.
send_push_data(
    Token,
    Data,
    #state{socket = Socket, address = Address, port = Port}
) ->
    Reply = pp_udp_socket:send(Socket, Data),
    TimerRef = erlang:send_after(?PUSH_DATA_TIMER, self(), {?PUSH_DATA_TICK, Token}),
    lager:debug("sent ~p/~p to ~p:~p replied: ~p", [Token, Data, Address, Port, Reply]),
    {Reply, TimerRef}.

-spec send_tx_ack(binary(), #state{}) -> ok | {error, any()}.
send_tx_ack(
    Token,
    #state{pubkeybin = PubKeyBin, socket = Socket, address = Address, port = Port}
) ->
    Data = semtech_udp:tx_ack(Token, pp_utils:pubkeybin_to_mac(PubKeyBin)),
    Reply = pp_udp_socket:send(Socket, Data),
    lager:debug("sent ~p/~p to ~p:~p replied: ~p", [Token, Data, Address, Port, Reply]),
    Reply.
