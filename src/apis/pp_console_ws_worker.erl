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
    activate/0,
    start_ws/0,
    start_ws/2,
    get_token/2,
    send_test/0
]).

-define(SERVER, ?MODULE).
-define(POOL, router_console_api_pool).
-define(HEADER_JSON, {<<"Content-Type">>, <<"application/json">>}).

-record(state, {
    ws :: undefind | pid(),
    ws_endpoint :: binary(),
    is_active :: boolean()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

deactivate() ->
    gen_server:call(?MODULE, deactivate).

activate() ->
    gen_server:call(?MODULE, activate).

start_ws() ->
    gen_server:call(?MODULE, start_ws).

send_test() ->
    Data = #{
        dc_used => #{balance => 0, nonce => 0, used => 0},
        organization_id => <<"e7b1829b-e009-4b8f-aea2-b1367635674c">>,
        packet_hash => <<"S5DJGXp4CRNl31/jajHj74eLFKAJcNXJAs/ulmbdtCI=">>,
        packet_size => 106,
        reported_at_epoch => 1637794127509,
        type => packet
    },
    ?MODULE:send(Data).

-spec handle_packet(
    NetID :: non_neg_integer(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    Type :: packet | join
) -> ok.
handle_packet(_NetID, Packet, PacketTime, Type) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    PayloadSize = erlang:byte_size(blockchain_helium_packet_v1:payload(Packet)),
    Data = #{
        %% FIXME: temporary value
        dc_used => #{
            balance => 0,
            nonce => 0,
            used => 0
        },
        packet_size => PayloadSize,
        %% FIXME: temporary value
        %% organization_id => NetID,
        organization_id => <<"e7b1829b-e009-4b8f-aea2-b1367635674c">>,
        reported_at_epoch => PacketTime,
        packet_hash => base64:encode(PHash),
        type => Type
    },
    ?MODULE:send(Data).

-spec send(Data :: any()) -> ok.
send(Data) ->
    gen_server:cast(?MODULE, {send_packet, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    WSEndpoint = maps:get(ws_endpoint, Args),
    Endpoint = maps:get(endpoint, Args),
    Secret = maps:get(secret, Args),
    lager:info("getting token for websocket from ~p", [Endpoint]),
    Token = get_token(Endpoint, Secret),
    IsActive = maps:get(is_active, Args, false),
    WSPid =
        case IsActive of
            true -> start_ws(WSEndpoint, Token);
            false -> undefined
        end,
    {ok, #state{
        ws = WSPid,
        ws_endpoint = WSEndpoint,
        is_active = IsActive
    }}.

handle_call(activate, _From, State) ->
    lager:info("activating websocket worker"),
    {reply, {ok, active}, State#state{is_active = true}};
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

handle_cast({send_packet, Data}, #state{is_active = true, ws = WSPid} = State) ->
    Ref = <<"0">>,
    Topic = <<"organization:all">>,
    Event = <<"packet_purchaser:new_packet">>,

    Payload = pp_console_ws_handler:encode_msg(Ref, Topic, Event, Data),
    websocket_client:cast(WSPid, {text, Payload}),

    {noreply, State};
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
    PubKeyBin = blockchain_swarm:pubkey_bin(),
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    Payload = pp_console_ws_handler:encode_msg(
        <<"0">>,
        <<"organization:all">>,
        <<"packet_purchaser:address">>,
        #{address => B58}
    ),
    ok = ?MODULE:send(Payload),
    {noreply, State};
handle_info(
    {
        ws_message,
        <<"organization:all">>,
        <<"organization:all:update">>,
        Payload
    },
    State
) ->
    lager:info("updating config to ~p", [Payload]),
    ok = pp_config:ws_update_config(Payload),
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
        auto_join => [<<"organization:all">>],
        forward => self()
    }),
    Pid.
