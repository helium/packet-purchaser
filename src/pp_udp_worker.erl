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
    push_data/5
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

-define(METRICS_PREFIX, "packet_purchaser_").


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
    ok = udp_worker_utils:update_address(WorkerPid, Protocol),
    gen_server:call(WorkerPid, {push_data, SCPacket, PacketTime, HandlerPid}).

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
            %% Pull data immediately so we can establish a connection for the first,
            %% pull_response.
            self() ! ?PULL_DATA_TICK,
            udp_worker_utils:schedule_pull_data(PullDataTimer)
    end,

    ok = pp_config:insert_udp_worker(NetID, self()),

    ShutdownTimeout = maps:get(shutdown_timer, Args, ?SHUTDOWN_TIMER),
    ShutdownRef = udp_worker_utils:schedule_shutdown(ShutdownTimeout),

    State = #pp_udp_worker_state{
        pubkeybin = PubKeyBin,
        net_id = NetID,
        socket = Socket,
        pull_data_timer = PullDataTimer,
        shutdown_timer = {ShutdownTimeout, ShutdownRef}
    },
    Location = pp_utils:get_hotspot_location(PubKeyBin),
    lager:info("got location ~p for hotspot", [Location]),
    {ok, State#pp_udp_worker_state{location = Location}}.

handle_call(
    {update_address, Address, Port},
    _From,
    #pp_udp_worker_state{socket = Socket0} = State
) ->
    Socket1 = udp_worker_utils:update_address(Socket0, Address, Port),
    {reply, ok, State#pp_udp_worker_state{socket = Socket1}};
handle_call(
    {push_data, SCPacket, PacketTime, HandlerPid},
    _From,
    #pp_udp_worker_state{push_data = PushData, location = Loc, shutdown_timer = {ShutdownTimeout, ShutdownRef},
        socket = Socket} =
        State
) ->
    _ = erlang:cancel_timer(ShutdownRef),
    {Token, Data} = handle_sc_packet_data(SCPacket, PacketTime, Loc),

    {Reply, TimerRef} = udp_worker_utils:send_push_data(Token, Data, Socket),
    {NewPushData, NewShutdownTimer} = udp_worker_utils:new_push_and_shutdown(Token, Data, TimerRef, PushData, ShutdownTimeout),

    {reply, Reply, State#pp_udp_worker_state{
        push_data = NewPushData,
        sc_pid = HandlerPid,
        pull_resp_fun = state_channel_send_response_function(HandlerPid),
        shutdown_timer = NewShutdownTimer
    }};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(get_hotspot_location, #pp_udp_worker_state{pubkeybin = PubKeyBin} = State) ->
    Location = pp_utils:get_hotspot_location(PubKeyBin),
    lager:info("got location ~p for hotspot", [Location]),
    {noreply, State#pp_udp_worker_state{location = Location}};
handle_info(
    {udp, Socket, _Address, Port, Data},
    #pp_udp_worker_state{
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
    #pp_udp_worker_state{push_data = PushData, net_id = NetID} = State
) ->
    case maps:get(Token, PushData, undefined) of
        undefined ->
            {noreply, State};
        {_Data, _} ->
            lager:debug("got push data timeout ~p, ignoring lack of ack", [Token]),
            ok = gwmp_metrics:push_ack_missed(?METRICS_PREFIX, NetID),
            {noreply, State#pp_udp_worker_state{push_data = maps:remove(Token, PushData)}}
    end;
handle_info(
    ?PULL_DATA_TICK,
    #pp_udp_worker_state{pubkeybin = PubKeyBin, socket = Socket, pull_data_timer = PullDataTimer} = State
) ->
    {ok, RefAndToken} = udp_worker_utils:send_pull_data(#{
        pubkeybin => PubKeyBin,
        socket => Socket,
        pull_data_timer => PullDataTimer
    }),
    {noreply, State#pp_udp_worker_state{pull_data = RefAndToken}};
handle_info(
    ?PULL_DATA_TIMEOUT_TICK,
    #pp_udp_worker_state{pull_data_timer = PullDataTimer, net_id = NetID} = State
) ->
    udp_worker_utils:handle_pull_data_timeout(PullDataTimer, NetID, ?METRICS_PREFIX),
    {noreply, State};
handle_info(?SHUTDOWN_TICK, #pp_udp_worker_state{shutdown_timer = {ShutdownTimeout, _}} = State) ->
    lager:info("shutting down, haven't sent data in ~p", [ShutdownTimeout]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #pp_udp_worker_state{socket = Socket}) ->
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
    #{
        pub_key_bin => PubKeyBin,
        mac => udp_worker_utils:pubkeybin_to_mac(PubKeyBin),
        region => Region,
        tmst => Tmst,
        payload => Payload,
        frequency => Frequency,
        datarate => Datarate,
        signal_strength =>SignalStrength,
        snr => Snr}.

-spec handle_udp(binary(), #pp_udp_worker_state{}) -> {noreply, #pp_udp_worker_state{}}.
handle_udp(Data, #pp_udp_worker_state{
    push_data = PushData,
    net_id = NetID,
    pull_data_timer = PullDataTimer,
    pull_data = PullData,
    socket = Socket,
    pull_resp_fun = PullRespFunction,
    pubkeybin = PubKeyBin} = State) ->
    StateUpdates =
        udp_worker_utils:handle_udp(Data, PushData, NetID, PullData, PullDataTimer, PubKeyBin, Socket, PullRespFunction, ?METRICS_PREFIX),
    {noreply, update_state(StateUpdates, State)}.

update_state(StateUpdates, InitialState) ->
    Fun = fun(Key, Value, State) ->
        case Key of
            push_data -> State#pp_udp_worker_state{push_data = Value};
            pull_data -> State#pp_udp_worker_state{pull_data = Value};
            _ -> State
        end
          end,
    maps:fold(Fun, InitialState, StateUpdates).

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

-spec state_channel_send_response_function(SCPid :: pid()) -> any().

state_channel_send_response_function(SCPid) ->
    fun(Data) -> state_channel_send_response(Data, SCPid) end.