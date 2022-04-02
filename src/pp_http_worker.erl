-module(pp_http_worker).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

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

-type packet() :: {
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    Location :: pp_location:location()
}.

-record(state, {
    copies = [] :: list(packet()),
    send_data_timer = 200 :: non_neg_integer(),
    address :: binary(),
    net_id :: binary()
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
    {ok, #state{
        address = Address,
        net_id = pp_utils:binary_to_hexstring(NetID)
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {handle_packet, SCPacket, PacketTime},
    #state{send_data_timer = Timeout, copies = []} = State0
) ->
    State1 = collect_packet(SCPacket, PacketTime, State0),
    schedule_send_data(Timeout),
    {noreply, State1};
handle_cast({handle_packet, SCPacket, PacketTime}, #state{} = State0) ->
    State1 = collect_packet(SCPacket, PacketTime, State0),
    {noreply, State1};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?SEND_DATA, #state{copies = Copies, address = URL, net_id = NetID} = State0) ->
    Body = pp_http:make_uplink_payload(NetID, Copies),
    ok = pp_http:send_data(URL, Body),
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

schedule_send_data(Timeout) ->
    erlang:send_after(Timeout, self(), ?SEND_DATA).

-spec collect_packet(
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    #state{}
) -> #state{}.
collect_packet(SCPacket, PacketTime, #state{copies = Copies} = State0) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    State0#state{
        copies = [
            {
                SCPacket,
                PacketTime,
                pp_location:get_hotspot_location(PubKeyBin)
            }
            | Copies
        ]
    }.
