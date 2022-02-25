%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser Console WS Worker ==
%%
%% - Restarts websocket connection if it goes down
%% - Handles Roaming Console messages forwarded from ws_handler
%% - Sending messages to Roaming Console
%%
%% @end
%%%-------------------------------------------------------------------
-module(pp_console_ws_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_packet/4
]).

%% ------------------------------------------------------------------
%% Send API
%% ------------------------------------------------------------------
-export([
    send/1,
    send_address/0,
    send_get_config/0,
    send_get_org_balances/0
]).

%% ------------------------------------------------------------------
%% Websocket Client API
%% ------------------------------------------------------------------
-export([
    ws_update_pid/1,
    ws_joined/0,
    ws_handle_message/3,
    ws_get_auto_join_topics/0
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

%% Topics
-define(ORGANIZATION_TOPIC, <<"organization:all">>).
-define(NET_ID_TOPIC, <<"net_id:all">>).

%% Sending events
-define(WS_SEND_GET_CONFIG, <<"packet_purchaser:get_config">>).
-define(WS_SEND_GET_ORG_BALANCES, <<"packet_purchaser:get_org_balances">>).
-define(WS_SEND_NEW_PACKET, <<"packet_purchaser:new_packet">>).
-define(WS_SEND_PP_ADDRESS, <<"packet_purchaser:address">>).

%% Listening events
-define(WS_RCV_CONFIG_LIST, <<"organization:all:config:list">>).
-define(WS_RCV_REFILL_BALANCE, <<"organization:all:refill:dc_balance">>).
-define(WS_RCV_DC_BALANCE_LIST, <<"organization:all:dc_balance:list">>).
-define(WS_RCV_STOP_PURCHASING_NET_ID, <<"net_id:all:stop_purchasing">>).
-define(WS_RCV_KEEP_PURCHASING_NET_ID, <<"net_id:all:keep_purchasing">>).
-define(WS_RCV_REFETCH_ADDRESS, <<"organization:all:refetch:packet_purchaser_address">>).

-record(state, {
    ws = undefined :: undefined | pid()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec ws_update_pid(pid()) -> ok.
ws_update_pid(Pid) ->
    gen_server:cast(?MODULE, {update_ws_pid, Pid}).

-spec ws_joined() -> ok.
ws_joined() ->
    ?MODULE:send_address(),
    ?MODULE:send_get_config().

-spec ws_handle_message(Topic :: binary(), Event :: binary(), Payload :: map()) -> ok.
ws_handle_message(Topic, Event, Payload) ->
    gen_server:cast(?MODULE, {ws_message, Topic, Event, Payload}).

-spec ws_get_auto_join_topics() -> list(binary()).
ws_get_auto_join_topics() ->
    [?ORGANIZATION_TOPIC, ?NET_ID_TOPIC].

-spec handle_packet(
    NetID :: non_neg_integer(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    Type :: packet | join
) -> ok.
handle_packet(NetID, Packet, PacketTime, Type) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    PayloadSize = erlang:byte_size(blockchain_helium_packet_v1:payload(Packet)),
    Used = pp_utils:calculate_dc_amount(PayloadSize),

    Data = #{
        dc_used => Used,
        packet_size => PayloadSize,
        net_id => NetID,
        reported_at_epoch => PacketTime,
        packet_hash => base64:encode(PHash),
        type => Type
    },

    Ref = <<"0">>,
    Topic = ?ORGANIZATION_TOPIC,
    Event = ?WS_SEND_NEW_PACKET,

    Payload = pp_console_ws_client:encode_msg(Ref, Topic, Event, Data),
    ok = pp_metrics:ws_send_msg(NetID),
    ?MODULE:send(Payload).

-spec send_address() -> ok.
send_address() ->
    PubKeyBin = blockchain_swarm:pubkey_bin(),
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    RouterAddressPayload = pp_console_ws_client:encode_msg(
        <<"0">>,
        ?ORGANIZATION_TOPIC,
        ?WS_SEND_PP_ADDRESS,
        #{address => B58}
    ),
    ?MODULE:send(RouterAddressPayload).

-spec send_get_config() -> ok.
send_get_config() ->
    %% This will request ALL organizations configs.
    Ref = <<"0">>,
    Topic = ?ORGANIZATION_TOPIC,
    Event = ?WS_SEND_GET_CONFIG,
    Payload = pp_console_ws_client:encode_msg(Ref, Topic, Event, #{}),
    ?MODULE:send(Payload).

-spec send_get_org_balances() -> ok.
send_get_org_balances() ->
    %% Get up to date balances for all orgs
    Ref = <<"0">>,
    Topic = ?ORGANIZATION_TOPIC,
    Event = ?WS_SEND_GET_ORG_BALANCES,
    Payload = pp_console_ws_client:encode_msg(Ref, Topic, Event, #{}),
    ?MODULE:send(Payload).

-spec send(Data :: any()) -> ok.
send(Data) ->
    gen_server:cast(?MODULE, {send, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({update_ws_pid, NewPid}, #state{ws = OldPid} = State) ->
    lager:info("ws connection pid updated [old: ~p] [new: ~p]", [OldPid, NewPid]),
    {noreply, State#state{ws = NewPid}};
handle_cast({send, Payload}, #state{ws = WSPid} = State) ->
    case WSPid of
        undefined ->
            lager:debug("send with no connection [payload: ~p]", [Payload]);
        _ ->
            websocket_client:cast(WSPid, {text, Payload})
    end,
    {noreply, State};
handle_cast({ws_message, Topic, Event, Payload}, State) ->
    handle_message(Topic, Event, Payload),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    lager:warning("went down ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Receive Message handler functions
%% ------------------------------------------------------------------
handle_message(
    ?ORGANIZATION_TOPIC,
    ?WS_RCV_CONFIG_LIST,
    #{<<"org_config_list">> := Config} = Payload
) ->
    UpdateFromWsConfig =
        case application:get_env(packet_purchaser, update_from_ws_config, false) of
            "true" -> true;
            true -> true;
            _ -> false
        end,
    lager:info("updating config: [updating: ~p] [payload: ~p]", [UpdateFromWsConfig, Payload]),
    ConfigParseable =
        try pp_config:transform_config(Config) of
            _ ->
                lager:info("valid config"),
                true
        catch
            Class:Err ->
                lager:error("could not parse config [error: ~p]", [{Class, Err}]),
                false
        end,
    case UpdateFromWsConfig andalso ConfigParseable of
        true ->
            pp_config:ws_update_config(Config);
        _ ->
            ok
    end,
    ok;
handle_message(?ORGANIZATION_TOPIC, ?WS_RCV_DC_BALANCE_LIST, Payload) ->
    lager:info("updating dc balances: ~p", [Payload]),
    ok;
handle_message(?ORGANIZATION_TOPIC, ?WS_RCV_REFILL_BALANCE, Payload) ->
    lager:info("refill DC balance: ~p", [Payload]),
    ok;
handle_message(?ORGANIZATION_TOPIC, ?WS_RCV_REFETCH_ADDRESS, Payload) ->
    ct:print("sending address: ~p", [Payload]),
    ?MODULE:send_address(),
    ok;
handle_message(?NET_ID_TOPIC, ?WS_RCV_KEEP_PURCHASING_NET_ID, #{<<"net_ids">> := NetIDs}) ->
    lager:info("keep purchasing: ~p", [NetIDs]),
    ok = pp_config:start_buying(NetIDs),
    ok;
handle_message(?NET_ID_TOPIC, ?WS_RCV_STOP_PURCHASING_NET_ID, #{<<"net_ids">> := NetIDs}) ->
    lager:info("stop purchasing: ~p", [NetIDs]),
    ok = pp_config:stop_buying(NetIDs),
    ok;
handle_message(Topic, Msg, Payload) ->
    case {Topic, Msg} of
        {?ORGANIZATION_TOPIC, <<"phx_reply">>} ->
            lager:debug(
                "organization websocket message [event: phx_reply] [payload: ~p]",
                [Payload]
            );
        {?ORGANIZATION_TOPIC, _} ->
            lager:warning(
                "rcvd unknown organization websocket message [event: ~p] [payload: ~p]",
                [Msg, Payload]
            );
        {?NET_ID_TOPIC, <<"phx_reply">>} ->
            lager:debug(
                "net_id websocket message [event: phx_reply] [payload: ~p]",
                [Payload]
            );
        {?NET_ID_TOPIC, _} ->
            lager:warning(
                "rcvd unknown net_id websocket message [event: ~p] [payload: ~p]",
                [Msg, Payload]
            );
        {_, _} ->
            lager:warning(
                "rcvd unknown topic message [topic: ~p] [event: ~p] [payload: ~p]",
                [Topic, Msg, Payload]
            )
    end,
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
