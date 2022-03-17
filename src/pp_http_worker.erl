-module(pp_http_worker).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_packet/3,
    send_data/1
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
-define(SEND_DATA_TICK, send_data_tick).

-record(state, {
    copies = [] :: [
        {
            SCPacket :: blockchain_state_channel_packet_v1:packet(),
            Location :: pp_location:location()
        }
    ],
    packet_time :: undefined | non_neg_integer(),
    send_data_timer = 200 :: non_neg_integer(),
    address :: binary(),
    port :: non_neg_integer(),
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

-spec send_data(WorkerPid :: pid()) -> ok.
send_data(Pid) ->
    gen_server:cast(Pid, send_data).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    #{address := Address, port := Port, net_id := NetID} = Args,
    ct:print("~p init with ~p", [?MODULE, Args]),
    {ok, #state{
        address = Address,
        port = Port,
        net_id = pp_utils:binary_to_hexstring(NetID)
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    send_data,
    #state{
        copies = [{SCPacket, _} | _] = Copies,
        address = Address,
        port = Port,
        packet_time = PacketTime,
        net_id = NetID
    } = State0
) ->
    %% TODO handle https
    URL = list_to_binary(
        io_lib:format("~p://~s:~p/new_thing", [http, Address, Port])
    ),

    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    RoutingInfo = blockchain_helium_packet_v1:routing_info(Packet),

    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    DataRate = blockchain_helium_packet_v1:datarate(Packet),
    Payload = blockchain_helium_packet_v1:payload(Packet),
    Frequency = blockchain_helium_packet_v1:frequency(Packet),

    {devaddr, DevAddr} = RoutingInfo,

    Body = #{
        'ProtocolVersion' => <<"1.0">>,
        'SenderID' => <<"0xC00053">>,
        'ReceiverID' => NetID,
        'TransactionID' => 3,
        'MessageType' => <<"PRStartReq">>,
        'PHYPayload' => pp_utils:binary_to_hexstring(Payload),
        'ULMetaData' => #{
            'DevAddr' => pp_utils:binary_to_hexstring(DevAddr),
            'DataRate' => pp_lorawan:datar_to_dr(Region, DataRate),
            'ULFreq' => Frequency,
            %% TODO: Is there a receive time we can use that isn't
            %% gateway dependent? Maybe the Tmst?
            'RecvTime' => pp_utils:format_time(PacketTime),
            'RFRegion' => Region,
            'GWInfo' => lists:map(fun gw_info/1, Copies)
        }
    },
    Res = hackney:post(URL, [], jsx:encode(Body), []),
    ct:print("~p Http Res: ~n~p", [URL, Res]),
    {stop, data_sent, State0};
handle_cast(
    {handle_packet, SCPacket, PacketTime},
    #state{send_data_timer = Timer, copies = []} = State0
) ->
    ct:print("first copy"),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    State1 = State0#state{
        copies = [{SCPacket, pp_location:get_hotspot_location(PubKeyBin)}],
        packet_time = PacketTime
    },
    schedule_send_data(Timer),
    {noreply, State1};
handle_cast(
    {handle_packet, SCPacket, _PacketTime},
    #state{copies = Copies} = State0
) ->
    ct:print("collecting another packet"),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    State1 = State0#state{
        copies = [{SCPacket, pp_location:get_hotspot_location(PubKeyBin)} | Copies]
    },
    {noreply, State1};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

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

gw_info({SCPacket, Location}) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),

    SNR = blockchain_helium_packet_v1:snr(Packet),
    RSSI = blockchain_helium_packet_v1:signal_strength(Packet),

    GW = #{
        'ID' => pp_utils:binary_to_hexstring(pp_utils:pubkeybin_to_mac(PubKeyBin)),
        'RFRegion' => Region,
        'RSSI' => RSSI,
        'SNR' => SNR,
        'DLAllowed' => true
    },
    case Location of
        {_Index, Lat, Long} ->
            GW#{'Lat' => Lat, 'Lon' => Long};
        _ ->
            GW
    end.

schedule_send_data(Timeout) ->
    timer:apply_after(Timeout, ?MODULE, send_data, [self()]).
