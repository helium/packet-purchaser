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

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    send/1,
    handle_packet/4
]).

-export([
    send_address/0,
    send_get_config/0,
    send_get_org_balances/0
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

-export([
    deactivate/0,
    activate/0, activate/1,
    start_ws/0,
    start_ws/2,
    get_token/2
]).

-define(SERVER, ?MODULE).
-define(POOL, router_console_api_pool).
-define(HEADER_JSON, {<<"Content-Type">>, <<"application/json">>}).

%% Channels
-define(ORGANIZATION, <<"organization:all">>).

%% Sending events
-define(WS_SEND_GET_CONFIG, <<"packet_purchaser:get_config">>).
-define(WS_SEND_GET_ORG_BALANCES, <<"packet_purchaser:get_org_balances">>).
-define(WS_SEND_NEW_PACKET, <<"packet_purchaser:new_packet">>).
-define(WS_SEND_PP_ADDRESS, <<"packet_purchaser:address">>).

%% Listening events
-define(WS_RCV_CONFIG_LIST, <<"organization:all:config:list">>).
-define(WS_RCV_REFILL_BALANCE, <<"organization:all:refill:dc_balance">>).
-define(WS_RCV_DC_BALANCE_LIST, <<"organization:all:dc_balance:list">>).

-record(state, {
    ws :: undefind | pid(),
    ws_endpoint :: binary(),
    is_active :: boolean() | {true, Limit :: integer()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec deactivate() -> ok.
deactivate() ->
    gen_server:call(?MODULE, deactivate).

-spec activate() -> ok.
activate() ->
    gen_server:call(?MODULE, activate).

-spec activate(non_neg_integer()) -> ok.
activate(Limit) ->
    gen_server:call(?MODULE, {activate, Limit}).

-spec start_ws() -> ok.
start_ws() ->
    gen_server:call(?MODULE, start_ws).

-spec handle_packet(
    NetID :: non_neg_integer(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    Type :: packet | join
) -> ok.
handle_packet(NetID, Packet, PacketTime, Type) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    PayloadSize = erlang:byte_size(blockchain_helium_packet_v1:payload(Packet)),
    Data = #{
        packet_size => PayloadSize,
        organization_id => NetID,
        reported_at_epoch => PacketTime,
        packet_hash => base64:encode(PHash),
        type => Type
    },

    Ref = <<"0">>,
    Topic = ?ORGANIZATION,
    Event = ?WS_SEND_NEW_PACKET,

    Payload = pp_console_ws_handler:encode_msg(Ref, Topic, Event, Data),
    ?MODULE:send(Payload).

-spec send_address() -> ok.
send_address() ->
    PubKeyBin = blockchain_swarm:pubkey_bin(),
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    RouterAddressPayload = pp_console_ws_handler:encode_msg(
        <<"0">>,
        ?ORGANIZATION,
        ?WS_SEND_PP_ADDRESS,
        #{address => B58}
    ),
    ok = ?MODULE:send(RouterAddressPayload).

-spec send_get_config() -> ok.
send_get_config() ->
    %% This will request ALL organizations configs.
    Ref = <<"0">>,
    Topic = ?ORGANIZATION,
    Event = ?WS_SEND_GET_CONFIG,
    Payload = pp_console_ws_handler:encode_msg(Ref, Topic, Event, #{}),
    ?MODULE:send(Payload).

-spec send_get_org_balances() -> ok.
send_get_org_balances() ->
    %% Get up to date balances for all orgs
    Ref = <<"0">>,
    Topic = ?ORGANIZATION,
    Event = ?WS_SEND_GET_ORG_BALANCES,
    Payload = pp_console_ws_handler:encode_msg(Ref, Topic, Event, #{}),
    ?MODULE:send(Payload).

-spec send(Data :: any()) -> ok.
send(Data) ->
    gen_server:cast(?MODULE, {send, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    WSEndpoint = maps:get(ws_endpoint, Args),
    Endpoint = maps:get(endpoint, Args),
    Secret = maps:get(secret, Args),
    IsActive = maps:get(is_active, Args, false),
    WSPid =
        case IsActive of
            true ->
                lager:info("getting token for websocket from ~p", [Endpoint]),
                Token = get_token(Endpoint, Secret),
                start_ws(WSEndpoint, Token);
            false ->
                undefined
        end,
    {ok, #state{
        ws = WSPid,
        ws_endpoint = WSEndpoint,
        is_active = IsActive
    }}.

handle_call(activate, _From, State) ->
    lager:info("activating websocket worker"),
    {reply, {ok, active}, State#state{is_active = true}};
handle_call({activate, Limit}, _From, State) ->
    lager:info("activating websocket for ~p messages", [Limit]),
    {reply, {ok, active}, State#state{is_active = {true, Limit}}};
handle_call(deactivate, _From, State) ->
    lager:info("deactivating websocket worker"),
    {reply, {ok, inactive}, State#state{is_active = false}};
handle_call(start_ws, _From, #state{ws_endpoint = WSEndpoint} = State) ->
    #{endpoint := Endpoint, secret := Secret} = maps:from_list(
        application:get_env(packet_purchaser, pp_console_api, [])
    ),
    Token = get_token(Endpoint, Secret),
    lager:info("starting websocket connection"),
    WSPid = start_ws(WSEndpoint, Token),
    {reply, {ok, WSPid}, State#state{ws = WSPid}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({send, _Payload}, #state{is_active = {true, 0}} = State) ->
    {noreply, State#state{is_active = false}};
handle_cast({send, Payload}, #state{is_active = true, ws = WSPid} = State) ->
    websocket_client:cast(WSPid, {text, Payload}),
    {noreply, State};
handle_cast({send, Payload}, #state{is_active = {true, Limit}, ws = WSPid} = State) ->
    websocket_client:cast(WSPid, {text, Payload}),
    {noreply, State#state{is_active = {true, Limit - 1}}};
handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {'EXIT', WSPid0, _Reason},
    #state{ws = WSPid0, ws_endpoint = WSEndpoint} = State
) ->
    lager:error("websocket connection went down: ~p, restarting", [_Reason]),
    #{endpoint := Endpoint, secret := Secret} = maps:from_list(
        application:get_env(packet_purchaser, pp_console_api, [])
    ),
    Token = get_token(Endpoint, Secret),
    WSPid1 = start_ws(WSEndpoint, Token),
    {noreply, State#state{ws = WSPid1}};
handle_info(ws_joined, #state{} = State) ->
    lager:info("joined, sending packet_purchaser address to console"),
    ok = ?MODULE:send_address(),
    ok = ?MODULE:send_get_config(),
    %% TODO: dc tracker
    %% ok = ?MODULE:send_get_org_balances(),
    {noreply, State};
handle_info({ws_message, Topic, Event, Payload}, State) ->
    ok = handle_message(Topic, Event, Payload),
    {noreply, State};
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
handle_message(?ORGANIZATION, ?WS_RCV_CONFIG_LIST, Payload) ->
    lager:info("updating config: ~p", [Payload]),
    ok = pp_config:ws_update_config(Payload);
handle_message(?ORGANIZATION, ?WS_RCV_DC_BALANCE_LIST, Payload) ->
    lager:info("updating dc balances: ~p", [Payload]),
    ok;
handle_message(?ORGANIZATION, ?WS_RCV_REFILL_BALANCE, Payload) ->
    lager:info("refill DC balance: ~p", [Payload]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec get_token(Endpoint :: binary(), Secret :: binary()) -> binary().
get_token(Endpoint, Secret) ->
    case
        hackney:post(
            <<Endpoint/binary, "/api/packet_purchaser/sessions">>,
            [?HEADER_JSON],
            jsx:encode(#{secret => Secret}),
            [with_body, {pool, ?POOL}]
        )
    of
        {ok, 201, _Headers, Body} ->
            #{<<"jwt">> := Token} = jsx:decode(Body, [return_maps]),
            Token;
        _Other ->
            lager:error("we failed to get a proper token ~p", [_Other]),
            erlang:throw(get_token)
    end.

-spec start_ws(WSEndpoint :: binary(), Token :: binary()) -> pid().
start_ws(WSEndpoint, Token) ->
    Url = binary_to_list(<<WSEndpoint/binary, "?token=", Token/binary, "&vsn=2.0.0">>),
    {ok, Pid} = pp_console_ws_handler:start_link(#{
        url => Url,
        auto_join => [?ORGANIZATION],
        forward => self()
    }),
    Pid.
