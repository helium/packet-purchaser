-module(pp_http_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_packet/3
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
-define(SEND_DATA, send_data).

-record(state, {
    http :: pp_http:http(),
    send_data_timer = 200 :: non_neg_integer(),
    send_data_timer_ref :: undefined | reference()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_packet(
    WorkerPid :: pid(),
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: pos_integer()
) -> ok | {error, any()}.
handle_packet(Pid, SCPacket, PacketTime) ->
    gen_server:cast(Pid, {handle_packet, SCPacket, PacketTime}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    #{protocol := {http, Address}, net_id := NetID} = Args,
    lager:debug("~p init with ~p", [?MODULE, Args]),
    {ok, #state{http = pp_http:new(pp_utils:binary_to_hexstring(NetID), Address)}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {handle_packet, SCPacket, PacketTime},
    #state{send_data_timer = Timeout, send_data_timer_ref = TimerRef0, http = Http0} = State
) ->
    {ok, Http1} = pp_http:handle_packet(SCPacket, PacketTime, Http0),
    {ok, TimerRef1} = maybe_schedule_send_data(Timeout, TimerRef0),
    {noreply, State#state{http = Http1, send_data_timer_ref = TimerRef1}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?SEND_DATA, #state{http = Http} = State0) ->
    ok = pp_http:send_data(Http),
    {stop, data_sent, State0};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{}) ->
    lager:info("going down ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

maybe_schedule_send_data(Timeout, undefined) ->
    {ok, erlang:send_after(Timeout, self(), ?SEND_DATA)};
maybe_schedule_send_data(_, Ref) ->
    {ok, Ref}.
