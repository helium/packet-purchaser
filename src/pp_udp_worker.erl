-module(pp_udp_worker).

-behavior(gen_server).

-include("packet_purchaser.hrl").

-include_lib("router_utils/include/semtech_udp.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    push_data/4,
    push_data/5,
    update_address/2
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

-define(PULL_DATA_TIMER, timer:seconds(10)).

-define(SHUTDOWN_TICK, shutdown_tick).
-define(SHUTDOWN_TIMER, timer:minutes(5)).

-define(METRICS_PREFIX, "packet_purchaser_").

-record(state, {
    location :: no_location | {pos_integer(), float(), float()} | undefined,
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    net_id :: non_neg_integer(),
    socket :: pp_udp_socket:socket(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    sc_pid :: undefined | pid(),
    pull_data :: {reference(), binary()} | undefined,
    pull_data_timer :: non_neg_integer(),
    shutdown_timer :: {Timeout :: non_neg_integer(), Timer :: reference()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec push_data(
    Pid :: pid(),
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: pos_integer(),
    HandlerPid :: pid()
) -> ok | {error, any()}.
push_data(WorkerPid, SCPacket, PacketTime, HandlerPid) ->
    gen_server:call(WorkerPid, {push_data, SCPacket, PacketTime, HandlerPid}).

-spec push_data(
    Pid :: pid(),
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: pos_integer(),
    HandlerPid :: pid(),
    Protocol :: {udp, string(), integer()}
) -> ok | {error, any()}.
push_data(WorkerPid, SCPacket, PacketTime, HandlerPid, Protocol) ->
    ok = update_address(WorkerPid, Protocol),
    gen_server:call(WorkerPid, {push_data, SCPacket, PacketTime, HandlerPid}).

-spec update_address(
    WorkerPid :: pid(),
    Protocol ::
        {udp, Address :: pp_udp_socket:socket_address(), Port :: pp_udp_socket:socket_port()}
) -> ok.
update_address(WorkerPid, {udp, Address, Port}) ->
    gen_server:call(WorkerPid, {update_address, Address, Port}).
%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),

    PubKeyBin = maps:get(pubkeybin, Args),
    NetID = maps:get(net_id, Args),
    Address = maps:get(address, Args),
    lager:md([{gateway_id, blockchain_utils:addr2name(PubKeyBin)}, {address, Address}]),

    Port = maps:get(port, Args),
    {ok, Socket} = pp_udp_socket:open({Address, Port}, maps:get(tee, Args, undefined)),

    DisablePullData = maps:get(disable_pull_data, Args, false),
    PullDataTimer = maps:get(pull_data_timer, Args, ?PULL_DATA_TIMER),
    case DisablePullData of
        true ->
            ok;
        false ->
            %% Pull data immediately so we can establish a connection for the first
            %% pull_response.
            self() ! ?PULL_DATA_TICK,
            udp_worker_utils:schedule_pull_data(PullDataTimer)
    end,

    ok = pp_config:insert_udp_worker(NetID, self()),

    ShutdownTimeout = maps:get(shutdown_timer, Args, ?SHUTDOWN_TIMER),
    ShutdownRef = schedule_shutdown(ShutdownTimeout),

    State = #state{
        pubkeybin = PubKeyBin,
        net_id = NetID,
        socket = Socket,
        pull_data_timer = PullDataTimer,
        shutdown_timer = {ShutdownTimeout, ShutdownRef}
    },
    case pp_utils:get_hotspot_location(PubKeyBin) of
        unknown ->
            lager:warning("failed to get location"),
            erlang:send_after(500, self(), get_hotspot_location),
            {ok, State};
        Location ->
            lager:info("got location ~p for hotspot", [Location]),
            {ok, State#state{location = Location}}
    end.

handle_call(
    {update_address, Address, Port},
    _From,
    #state{socket = Socket0} = State
) ->
    lager:debug("Updating address and port [old: ~p] [new: ~p]", [
        pp_udp_socket:get_address(Socket0),
        {Address, Port}
    ]),
    {ok, Socket1} = pp_udp_socket:update_address(Socket0, {Address, Port}),
    {reply, ok, State#state{socket = Socket1}};
handle_call(
    {push_data, SCPacket, PacketTime, HandlerPid},
    _From,
    #state{push_data = PushData, location = Loc, shutdown_timer = {ShutdownTimeout, ShutdownRef}} =
        State
) ->
    _ = erlang:cancel_timer(ShutdownRef),
    {Token, Data} = handle_sc_packet_data(SCPacket, PacketTime, Loc),
    {Reply, TimerRef} = send_push_data(Token, Data, State),
    {reply, Reply, State#state{
        push_data = maps:put(Token, {Data, TimerRef}, PushData),
        sc_pid = HandlerPid,
        shutdown_timer = {ShutdownTimeout, schedule_shutdown(ShutdownTimeout)}
    }};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(get_hotspot_location, #state{pubkeybin = PubKeyBin} = State) ->
    case pp_utils:get_hotspot_location(PubKeyBin) of
        unknown ->
            lager:warning("failed to get location"),
            erlang:send_after(500, self(), get_hotspot_location),
            {noreply, State};
        Location ->
            lager:info("got location ~p for hotspot", [Location]),
            {noreply, State#state{location = Location}}
    end;
handle_info(
    {udp, Socket, _Address, Port, Data},
    #state{
        socket = {socket, Socket, _}
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
    #state{push_data = PushData, net_id = NetID} = State
) ->
    case maps:get(Token, PushData, undefined) of
        undefined ->
            {noreply, State};
        {_Data, _} ->
            lager:debug("got push data timeout ~p, ignoring lack of ack", [Token]),
            ok = gwmp_metrics:push_ack_missed(?METRICS_PREFIX, NetID),
            {noreply, State#state{push_data = maps:remove(Token, PushData)}}
    end;
handle_info(
    ?PULL_DATA_TICK,
    #state{pubkeybin = PubKeyBin, socket = Socket, pull_data_timer = PullDataTimer} = State
) ->
    {ok, RefAndToken} = udp_worker_utils:send_pull_data(#{
        pubkeybin => PubKeyBin,
        socket => Socket,
        pull_data_timer => PullDataTimer
    }),
    {noreply, State#state{pull_data = RefAndToken}};
handle_info(
    ?PULL_DATA_TIMEOUT_TICK,
    #state{pull_data_timer = PullDataTimer, net_id = NetID} = State
) ->
    udp_worker_utils:handle_pull_data_timeout(PullDataTimer, NetID, ?METRICS_PREFIX),
    {noreply, State};
handle_info(?SHUTDOWN_TICK, #state{shutdown_timer = {ShutdownTimeout, _}} = State) ->
    lager:info("shutting down, haven't sent data in ~p", [ShutdownTimeout]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{socket = Socket}) ->
    lager:info("going down ~p", [_Reason]),
    ok = pp_config:delete_udp_worker(self()),
    ok = pp_udp_socket:close(Socket),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_sc_packet_data(
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: pos_integer(),
    Location :: {pos_integer(), float(), float()} | no_location | undefined
) -> {binary(), binary()}.
handle_sc_packet_data(SCPacket, PacketTime, Location) ->
    PushDataMap = values_for_push_from(SCPacket),
    udp_worker_utils:handle_push_data(PushDataMap, Location, PacketTime).

values_for_push_from(SCPacket) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    Tmst = blockchain_helium_packet_v1:timestamp(Packet),
    Payload = blockchain_helium_packet_v1:payload(Packet),
    Frequency = blockchain_helium_packet_v1:frequency(Packet),
    Datarate = blockchain_helium_packet_v1:datarate(Packet),
    SignalStrength = blockchain_helium_packet_v1:signal_strength(Packet),
    Snr = blockchain_helium_packet_v1:snr(Packet),
    #{pub_key_bin => PubKeyBin,
        region => Region,
        tmst => Tmst,
        payload => Payload,
        frequency => Frequency,
        datarate => Datarate,
        signal_strength =>SignalStrength,
        snr => Snr}.

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
        push_data = PushData,
        net_id = NetID
    } = State
) ->
    NewPushData = udp_worker_utils:handle_push_ack(Data, PushData, NetID, ?METRICS_PREFIX),
    {noreply, State#state{push_data = NewPushData}}.

-spec handle_pull_ack(binary(), #state{}) -> {noreply, #state{}}.
handle_pull_ack(
    _Data,
    #state{pull_data = undefined} = State) ->
    lager:warning("got unknown pull ack for ~p", [_Data]),
    {noreply, State};
handle_pull_ack(
    Data,
    #state{
        pull_data = {PullDataRef, PullDataToken},
        pull_data_timer = PullDataTimer,
        net_id = NetID
    } = State
) ->
    NewPullData = udp_worker_utils:handle_pull_ack(Data, PullDataToken, PullDataRef, PullDataTimer, NetID, ?METRICS_PREFIX),
    case NewPullData of
        undefined ->
            {noreply, State#state{pull_data = undefined}};
        _ ->
            {noreply, State}
    end.

% TODO: Handle queueing downlinks
-spec handle_pull_resp(binary(), #state{}) -> {noreply, #state{}}.
handle_pull_resp(
    Data,
    #state{sc_pid = SCPid,
        pubkeybin = PubKeyBin,
        socket = Socket} = State
) when is_pid(SCPid) ->
    _ = state_channel_send_response(Data, SCPid),
    udp_worker_utils:handle_pull_response(Data, PubKeyBin, Socket),
    {noreply, State}.

state_channel_send_response(Data, SCPid) ->
    Map = maps:get(<<"txpk">>, semtech_udp:json_data(Data)),
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
    ).


-spec schedule_shutdown(non_neg_integer()) -> reference().
schedule_shutdown(ShutdownTimer) ->
    _ = erlang:send_after(ShutdownTimer, self(), ?SHUTDOWN_TICK).



-spec send_push_data(binary(), binary(), #state{}) -> {ok | {error, any()}, reference()}.
send_push_data(
    Token,
    Data,
    #state{socket = Socket}
) ->
    Reply = pp_udp_socket:send(Socket, Data),
    TimerRef = erlang:send_after(?PUSH_DATA_TIMER, self(), {?PUSH_DATA_TICK, Token}),
    lager:debug("sent ~p/~p to ~p replied: ~p", [
        Token,
        Data,
        pp_udp_socket:get_address(Socket),
        Reply
    ]),
    {Reply, TimerRef}.