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
-define(TIMEOUT, timer:seconds(10)).

-record(state, {
    phash :: binary(),
    configs :: {error, any()} | {ok, list(map())},
    packet_type :: join | packet,
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

    lager:debug("~p init with ~p for ~p", [?MODULE, Configs, NetIDs]),

    lists:foreach(fun(NetID) -> pp_metrics:handle_unique_frame(NetID, PacketType) end, NetIDs),

    {ok, #state{
        phash = PHash,
        configs = Configs,
        packet_type = PacketType,
        routing = Routing,
        net_ids = NetIDs
    }}.

handle_call(
    {handle_offer, Offer},
    _From,
    #state{configs = Configs, routing = Routing, net_ids = NetIDs} = State
) ->
    Resp =
        case Configs of
            {error, _} ->
                Configs;
            {ok, InnerConfigs} ->
                MultiBuyMax = lists:max([maps:get(multi_buy, M) || M <- InnerConfigs]),
                Res = pp_multi_buy:maybe_buy_offer(Offer, MultiBuyMax),
                Res
        end,
    erlang:spawn(fun() ->
        handle_offer_resp(Routing, NetIDs, Offer, Resp)
    end),
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
        fun(#{net_id := NetID, protocol := Protocol} = WorkerArgs) ->
            case Protocol of
                {udp, _, _} ->
                    case pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, WorkerArgs) of
                        {ok, Pid} ->
                            ct:print("pushing to udp worker: ~p", [NetID]),
                            ok = pp_metrics:handle_packet(PubKeyBin, NetID, PacketType, udp),
                            ok = pp_console_ws_worker:handle_packet(NetID, Packet, GatewayTime, PacketType),
                            pp_udp_worker:push_data(Pid, SCPacket, GatewayTime, HandlerPid, Protocol);
                        {error, worker_not_started} ->
                            lager:error(
                                [{packet_type, PacketType}, {net_id, NetID}],
                                "failed to start udp connector for: ~p",
                                [blockchain_utils:addr2name(PubKeyBin)]
                            )
                    end;
                #http_protocol{} ->
                    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
                    case pp_http_sup:maybe_start_worker({NetID, PHash, Protocol}, WorkerArgs) of
                        {ok, Pid} ->
                            ProtocolType =
                                case Protocol#http_protocol.flow_type of
                                    sync -> http_sync;
                                    async -> http_async
                                end,
                            ok = pp_metrics:handle_packet(PubKeyBin, NetID, PacketType, ProtocolType),
                            ok = pp_console_ws_worker:handle_packet(NetID, Packet, GatewayTime, PacketType),
                            pp_http_worker:handle_packet(Pid, SCPacket, GatewayTime);
                        {error, worker_not_started, _} ->
                            lager:error(
                                [{packet_type, PacketType}, {net_id, NetID}],
                                "fialed to start http connector for: ~p",
                                [blockchain_utils:addr2name(PubKeyBin)]
                            )
                    end
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

-spec get_packet_type(Routing :: pp_config:eui() | pp_config:devaddr()) -> join | packet.
get_packet_type({devaddr, _}) -> packet;
get_packet_type({eui, _, _}) -> join;
get_packet_type({eui, _}) -> join.

-spec get_net_ids(
    Routing :: pp_config:eui() | pp_config:devaddr(),
    Configs :: {error, any()} | {ok, list(map())}
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

-spec handle_offer_resp(
    Routing :: {devaddr, non_neg_integer()} | {eui, blockchain_state_channel_v1_pb:eui_pb()},
    NetIDs :: list(atom() | non_neg_integer()),
    Offer :: blockchain_state_channel_offer_v1:offer(),
    Resp :: ok | {error, any()}
) -> ok.

handle_offer_resp(Routing, NetIDs, Offer, Resp) ->
    PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),

    Action =
        case Resp of
            ok -> accepted;
            {error, _} -> rejected
        end,
    OfferType =
        case Routing of
            {eui, _} -> join;
            {devaddr, _} -> packet
        end,

    PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
    lists:foreach(
        fun(NetID) ->
            ok = pp_metrics:handle_offer(PubKeyBin, NetID, OfferType, Action, PayloadSize),

            lager:debug(
                [{action, Action}, {offer_type, OfferType}, {net_id, NetID}],
                "offer: ~s ~s [net_id: ~p] [routing: ~p] [resp: ~p]",
                [Action, OfferType, NetID, Routing, Resp]
            )
        end,
        NetIDs
    ).
