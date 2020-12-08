-module(packet_purchaser_udp_worker).

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
    push_data/3
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
    socket :: gen_udp:socket(),
    address :: inet:socket_address() | inet:hostname(),
    port :: inet:port_number(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    pull_data :: {reference(), binary()} | undefined,
    pull_data_timer :: non_neg_integer()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec push_data(pid(), binary(), binary()) -> ok | {error, any()}.
push_data(Pid, Token, Data) ->
    gen_server:call(Pid, {push_data, Token, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    % TODO: Add lager MD here for hotspot name
    process_flag(trap_exit, true),
    PubKeyBin = maps:get(pubkeybin, Args),
    lager:md([{gateway_id, blockchain_utils:addr2name(PubKeyBin)}]),
    lager:info("~p init with ~p", [?SERVER, Args]),
    Address = maps:get(address, Args),
    Port = maps:get(port, Args),
    PullDataTimer = maps:get(pull_data_timer, Args, ?PULL_DATA_TIMER),
    {ok, Socket} = gen_udp:open(0, [binary, {active, true}]),
    _ = schedule_pull_data(PullDataTimer),
    {ok, #state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        address = Address,
        port = Port,
        pull_data_timer = PullDataTimer
    }}.

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
        pull_data = PullData,
        pull_data_timer = PullDataTimer
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
                    _ = schedule_pull_data(PullDataTimer),
                    {noreply, State#state{pull_data = undefined}};
                _UnknownToken ->
                    lager:warning("got unknown pull ack for ~p", [_UnknownToken]),
                    {noreply, State}
            end;
        ?PULL_RESP ->
            % TODO: Send pull resp data to state channels
            Token = semtech_udp:token(Data),
            _ = send_tx_ack(Token, State),
            {noreply, State};
        _ ->
            {noreply, State}
    end;
handle_info(
    {?PUSH_DATA_TICK, Token},
    #state{push_data = PushData} = State
) ->
    case maps:get(Token, PushData, undefined) of
        undefined ->
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
    State
) ->
    lager:error("got a pull data timeout closing down"),
    {stop, pull_data_timeout, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{socket = Socket}) ->
    lager:info("going down ~p", [_Reason]),
    ok = gen_udp:close(Socket),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec schedule_pull_data(non_neg_integer()) -> reference().
schedule_pull_data(PullDataTimer) ->
    _ = erlang:send_after(PullDataTimer, self(), ?PULL_DATA_TICK).

-spec send_pull_data(#state{}) -> {ok, {reference(), binary()}} | {error, any()}.
send_pull_data(
    #state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        address = Address,
        port = Port,
        pull_data_timer = PullDataTimer
    }
) ->
    Token = semtech_udp:token(),
    Data = semtech_udp:pull_data(Token, packet_purchaser_utils:pubkeybin_to_mac(PubKeyBin)),
    case gen_udp:send(Socket, Address, Port, Data) of
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
    Reply = gen_udp:send(Socket, Address, Port, Data),
    TimerRef = erlang:send_after(?PUSH_DATA_TIMER, self(), {?PUSH_DATA_TICK, Token}),
    lager:debug("sent ~p/~p to ~p:~p replied: ~p", [Token, Data, Address, Port, Reply]),
    {Reply, TimerRef}.

-spec send_tx_ack(binary(), #state{}) -> ok | {error, any()}.
send_tx_ack(
    Token,
    #state{pubkeybin = PubKeyBin, socket = Socket, address = Address, port = Port}
) ->
    Data = semtech_udp:tx_ack(Token, packet_purchaser_utils:pubkeybin_to_mac(PubKeyBin)),
    Reply = gen_udp:send(Socket, Address, Port, Data),
    lager:debug("sent ~p/~p to ~p:~p replied: ~p", [Token, Data, Address, Port, Reply]),
    Reply.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
