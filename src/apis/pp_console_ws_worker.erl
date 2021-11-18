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
    send/1, send/3
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

-record(state, {
    ws :: pid(),
    ws_endpoint :: binary()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec send(
    NetID :: non_neg_integer(),
    Packet :: blockchain_state_channel_packet_v1:packet(),
    Type :: packet | join
) -> ok.
send(NetID, _Packet, Type) ->
    %% PayloadSize = erlang:byte_size(Packet#packet_pb.payload),
    %% Used = calculate_dc_amount(PayloadSize),
    Data = #{
        timestamp => erlang:system_time(millisecond),
        net_id => NetID,
        type => Type
        %% ,dc => #{
        %%     balance => todo,
        %%     nonce => todo,
        %%     used => Used
        %% }
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
    WSPid = start_ws(WSEndpoint),
    {ok, #state{
        ws = WSPid,
        ws_endpoint = WSEndpoint
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({send_packet, Data}, #state{ws = WSPid} = State) ->
    Ref = <<"TEST_REF">>,
    Topic = <<"roaming">>,
    Event = <<"packet">>,

    Payload = pp_console_ws_handler:encode_msg(Ref, Topic, Event, Data),
    websocket_client:cast(WSPid, {text, Payload}),

    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {'EXIT', WSPid0, _Reason},
    #state{ws = WSPid0, ws_endpoint = WSEndpoint} = State
) ->
    lager:error("websocket connection went down: ~p, restarting", [_Reason]),
    WSPid1 = start_ws(WSEndpoint),
    {noreply, State#state{ws = WSPid1}};
handle_info(ws_joined, #state{} = State) ->
    lager:info("joined, sending router address to console", []),
    {noreply, State};
handle_info(
    {
        ws_message,
        <<"org:all">>,
        <<"org:all:update">>,
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
-spec start_ws(WSEndpoint :: binary()) -> pid().
start_ws(WSEndpoint) ->
    Url = binary_to_list(WSEndpoint),
    {ok, Pid} = pp_console_ws_handler:start_link(#{
        url => Url,
        forward => self()
    }),
    Pid.
