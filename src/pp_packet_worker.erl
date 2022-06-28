-module(pp_packet_worker).

-behavior(gen_server).

-include("config.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_offer/2,
    handle_packet/4
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
-export([get_net_ids/2]).

-define(SERVER, ?MODULE).
-define(TIMEOUT, timer:seconds(60)).

-type config_maps() :: {ok, list(map())} | {error, any()}.

-record(state, {
    phash :: binary(),
    configs :: config_maps(),
    packet_type :: join | packet,
    max_multi_buy :: non_neg_integer() | unlimited,
    routing :: {devaddr, any()} | {eui, any()} | {eui, any(), any()},
    net_ids :: list(atom() | non_neg_integer())
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_offer(
    WorkerPid :: pid(),
    Offer :: blockchain_state_channel_offer_v1:offer()
) -> ok | {error, any()}.
handle_offer(Pid, Offer) ->
    gen_server:call(Pid, {handle_offer, Offer}).

-spec handle_packet(
    WorkerPid :: pid(),
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    GatewayTime :: pp_roaming_protocol:gateway_time(),
    HandlerPid :: pid()
) -> ok | {error, any()}.
handle_packet(Pid, SCPacket, GatewayTime, HandlerPid) ->
    gen_server:cast(Pid, {handle_packet, SCPacket, GatewayTime, HandlerPid}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{routing := Routing, phash := PHash}) ->
    Configs = pp_config:lookup(Routing),
    PacketType = get_packet_type(Routing),
    NetIDs = get_net_ids(Routing, Configs),
    MaxMultiBuy = get_max_multi_buy(Configs),

    lager:debug("~p init with ~p for ~p", [?MODULE, Configs, NetIDs]),

    lists:foreach(fun(NetID) -> pp_metrics:handle_unique_frame(NetID, PacketType) end, NetIDs),

    {ok, #state{
        phash = PHash,
        configs = Configs,
        packet_type = PacketType,
        max_multi_buy = MaxMultiBuy,
        routing = Routing,
        net_ids = NetIDs
    }}.

handle_call(
    {handle_offer, Offer},
    _From,
    #state{
        max_multi_buy = MaxMultiBuy,
        configs = Configs,
        net_ids = NetIDs,
        packet_type = PacketType
    } = State
) ->
    Resp =
        case Configs of
            {error, _} ->
                Configs;
            {ok, _} ->
                pp_multi_buy:maybe_buy_offer(Offer, MaxMultiBuy)
        end,
    Action =
        case Resp of
            ok -> accepted;
            {error, _} -> rejected
        end,
    lists:foreach(
        fun(NetID) -> ok = pp_metrics:handle_offer(NetID, PacketType, Action) end,
        NetIDs
    ),
    {reply, Resp, State, ?TIMEOUT};
handle_call(_Msg, _From, State) ->
    ct:print("rcvd unknown call msg: ~p from: ~p with: ~p", [_Msg, _From, State]),
    {reply, unhandled, State, ?TIMEOUT}.

handle_cast(
    {handle_packet, SCPacket, GatewayTime, HandlerPid},
    #state{configs = {ok, Configs}, packet_type = PacketType} = State
) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    lists:foreach(
        fun
            (#{net_id := NetID, protocol := {udp, _, _} = Protocol} = WorkerArgs) ->
                case pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, WorkerArgs) of
                    {ok, Pid} ->
                        ok = pp_metrics:handle_packet(PubKeyBin, NetID, PacketType, udp),
                        ok = pp_console_ws_worker:handle_packet(
                            NetID,
                            Packet,
                            GatewayTime,
                            PacketType
                        ),
                        pp_udp_worker:push_data(Pid, SCPacket, GatewayTime, HandlerPid, Protocol);
                    {error, worker_not_started} ->
                        lager:error(
                            [{packet_type, PacketType}, {net_id, NetID}],
                            "failed to start udp connector for: ~p",
                            [blockchain_utils:addr2name(PubKeyBin)]
                        )
                end;
            (#{net_id := NetID, protocol := #http_protocol{} = Protocol} = WorkerArgs) ->
                PHash = blockchain_helium_packet_v1:packet_hash(Packet),
                case pp_http_sup:maybe_start_worker({NetID, PHash, Protocol}, WorkerArgs) of
                    {ok, Pid} ->
                        ProtocolType =
                            case Protocol#http_protocol.flow_type of
                                sync -> http_sync;
                                async -> http_async
                            end,
                        ok = pp_metrics:handle_packet(PubKeyBin, NetID, PacketType, ProtocolType),
                        ok = pp_console_ws_worker:handle_packet(
                            NetID,
                            Packet,
                            GatewayTime,
                            PacketType
                        ),
                        pp_http_worker:handle_packet(Pid, SCPacket, GatewayTime);
                    {error, worker_not_started, _} ->
                        lager:error(
                            [{packet_type, PacketType}, {net_id, NetID}],
                            "fialed to start http connector for: ~p",
                            [blockchain_utils:addr2name(PubKeyBin)]
                        )
                    %% end
                end
        end,
        Configs
    ),
    {noreply, State, ?TIMEOUT};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State, ?TIMEOUT}.

handle_info(timeout, State) ->
    lager:debug("going down on timeout"),
    {stop, normal, State};
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

-spec get_max_multi_buy(config_maps()) -> non_neg_integer() | unlimited.
get_max_multi_buy(Configs) ->
    case Configs of
        {error, _} -> 0;
        {ok, Inner} -> lists:max([maps:get(multi_buy, M) || M <- Inner])
    end.

-spec get_packet_type(Routing :: pp_config:eui() | pp_config:devaddr()) -> join | packet.
get_packet_type({devaddr, _}) -> packet;
get_packet_type({eui, _, _}) -> join;
get_packet_type({eui, _}) -> join.

-spec get_net_ids(
    Routing :: pp_config:eui() | pp_config:devaddr(),
    Configs :: config_maps()
) -> list(atom() | non_neg_integer()).
get_net_ids({devaddr, DevAddr}, _) ->
    case pp_lorawan:parse_netid(DevAddr) of
        {error, Reason} -> [Reason];
        {_, NetID} -> [NetID]
    end;
get_net_ids(_, {error, Reason}) ->
    [Reason];
get_net_ids(_, {ok, Configs}) ->
    [NetID || #{net_id := NetID} <- Configs].
