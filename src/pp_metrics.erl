-module(pp_metrics).

-behaviour(gen_server).
-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

-define(METRICS_UNIQUE_OFFER_COUNT, packet_purchaser_unique_offer_count).
-define(METRICS_OFFER_COUNT, packet_purchaser_offer_count).
-define(METRICS_PACKET_COUNT, packet_purchaser_packet_count).
-define(METRICS_GWMP_COUNT, packet_purchaser_gwmp_counter).
-define(METRICS_DC_BALANCE, packet_purchaser_dc_balance).
-define(METRICS_CHAIN_BLOCKS, packet_purchaser_blockchain_blocks).

-define(METRICS_SC_OPENED_COUNT, packet_purchaser_state_channel_opened_count).
-define(METRICS_SC_OVERSPENT_COUNT, packet_purchaser_state_channel_overspent_count).
-define(METRICS_SC_ACTIVE_COUNT, packet_purchaser_state_channel_active_count).
-define(METRICS_SC_ACTIVE_BALANCE, packet_purchaser_state_channel_active_balance).
-define(METRICS_SC_ACTIVE_ACTORS, packet_purchaser_state_channel_active_actors).
-define(METRICS_SC_CLOSE_SUBMIT, packet_purchaser_state_channel_close_submit_count).
-define(METRICS_SC_CLOSE_CONFLICT, packet_purchaser_state_channel_close_conflicts).

-define(METRICS_WS_STATE, packet_purchaser_ws_state).
-define(METRICS_WS_MSG_COUNT, packet_purchaser_ws_msg_count).

-define(METRICS_VM_CPU, packet_purchaser_vm_cpu).
-define(METRICS_VM_PROC_Q, packet_purchaser_vm_process_queue).
-define(METRICS_VM_ETS_MEMORY, packet_purchaser_vm_ets_memory).

-define(METRICS_GRPC_CONNECTION_COUNT, packet_purchaser_connection_count).

-define(METRICS_WORKER_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_WORKER_TICK, '__pp_metrics_tick').

%% gen_server API
-export([start_link/1]).

%% Prometheus API
-export([
    handle_unique_offer/2,
    handle_offer/4,
    handle_packet/4,
    %% Stats
    dcs/1,
    blocks/1,
    state_channels/5,
    state_channel_close/1,
    %% Websocket
    ws_state/1,
    ws_send_msg/1
]).

%% Helper API
-export([init_ets/0]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Elli API
-export([
    handle/2,
    handle_event/3
]).

-define(UNIQUE_OFFER_ETS, pp_metrics_unique_offer_ets).

-record(state, {
    chain = undefined :: undefined | blockchain:blockchain(),
    pubkey_bin :: libp2p_crypto:pubkey_bin()
}).

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

%% -------------------------------------------------------------------
%% Prometheus API Functions
%% -------------------------------------------------------------------

-spec handle_unique_offer(NetID :: non_neg_integer(), Type :: join | packet) -> ok.
handle_unique_offer(NetID, Type) ->
    prometheus_counter:inc(?METRICS_UNIQUE_OFFER_COUNT, [gwmp_metrics:clean_net_id(NetID), Type]).

-spec handle_offer(
    NetID :: non_neg_integer(),
    OfferType :: join | packet,
    Action :: accepted | rejected,
    PHash :: binary()
) -> ok.
handle_offer(NetID, OfferType, Action, PHash) ->
    _ = ets:insert(?UNIQUE_OFFER_ETS, {{NetID, PHash, OfferType}, erlang:system_time(millisecond)}),
    prometheus_counter:inc(?METRICS_OFFER_COUNT, [gwmp_metrics:clean_net_id(NetID), OfferType, Action]).

-spec handle_packet(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    NetID :: non_neg_integer(),
    PacketType :: join | packet,
    ProtocolType :: udp | http_sync | http_async
) -> ok.
handle_packet(_PubKeyBin, NetID, PacketType, ProtocolType) ->
    prometheus_counter:inc(?METRICS_PACKET_COUNT, [gwmp_metrics:clean_net_id(NetID), PacketType, ProtocolType]).

-spec dcs(Balance :: non_neg_integer()) -> ok.
dcs(Balance) ->
    prometheus_gauge:set(?METRICS_DC_BALANCE, Balance).

-spec blocks(RelativeTime :: integer()) -> ok.
blocks(RelativeTime) ->
    prometheus_gauge:set(?METRICS_CHAIN_BLOCKS, RelativeTime).

-spec state_channels(
    OpenedCount :: non_neg_integer(),
    OverspentCount :: non_neg_integer(),
    ActiveCount :: non_neg_integer(),
    TotalDCLeft :: non_neg_integer(),
    TotalActors :: non_neg_integer()
) -> ok.
state_channels(OpenedCount, OverspentCount, ActiveCount, TotalDCLeft, TotalActors) ->
    prometheus_gauge:set(?METRICS_SC_OPENED_COUNT, OpenedCount),
    prometheus_gauge:set(?METRICS_SC_OVERSPENT_COUNT, OverspentCount),
    prometheus_gauge:set(?METRICS_SC_ACTIVE_COUNT, ActiveCount),
    prometheus_gauge:set(?METRICS_SC_ACTIVE_BALANCE, TotalDCLeft),
    prometheus_gauge:set(?METRICS_SC_ACTIVE_ACTORS, TotalActors).

-spec state_channel_close(Status :: ok | error) -> ok.
state_channel_close(Status) ->
    prometheus_counter:inc(?METRICS_SC_CLOSE_SUBMIT, [Status]).

-spec ws_state(boolean()) -> ok.
ws_state(State) ->
    prometheus_boolean:set(?METRICS_WS_STATE, State).

-spec ws_send_msg(NetID :: non_neg_integer()) -> ok.
ws_send_msg(NetID) ->
    prometheus_counter:inc(?METRICS_WS_MSG_COUNT, [NetID]).

%% -------------------------------------------------------------------
%% gen_server Callbacks
%% -------------------------------------------------------------------

init(Args) ->
    ElliOpts = [
        {callback, ?MODULE},
        {port, proplists:get_value(port, Args, 3000)}
    ],
    {ok, _Pid} = elli:start_link(ElliOpts),

    {ok, PubKey, _, _} = blockchain_swarm:keys(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Timer = proplists:get_value(unique_offers_cleanup_timer, Args, 10),
    Window = proplists:get_value(unique_offers_window, Args, 60),

    ok = declare_metrics(),
    ok = spawn_crawl_offers(timer:seconds(Timer), timer:seconds(Window)),

    _ = erlang:send_after(500, self(), post_init),

    {ok, #state{pubkey_bin = PubKeyBin}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(post_init, #state{chain = undefined} = State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            _ = schedule_next_tick(),
            {noreply, State#state{chain = Chain}}
    end;
handle_info({blockchain_event, {new_chain, Chain}}, State) ->
    {noreply, State#state{chain = Chain}};
handle_info(
    {blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}},
    #state{chain = undefined} = State
) ->
    erlang:send_after(500, self(), post_init),
    {noreply, State};
handle_info(
    {blockchain_event, {add_block, BlockHash, _Syncing, _Ledger}},
    #state{chain = Chain, pubkey_bin = PubkeyBin} = State
) ->
    _ = erlang:spawn(fun() -> ok = record_sc_close_conflict(Chain, BlockHash, PubkeyBin) end),
    {noreply, State};
handle_info(?METRICS_WORKER_TICK, #state{pubkey_bin = PubKeyBin} = State) ->
    lager:info("running metrics"),
    erlang:spawn(fun() ->
        ok = record_dc_balance(PubKeyBin),
        ok = record_chain_blocks(),
        ok = record_state_channels(),
        ok = record_vm_stats(),
        ok = record_ets(),
        ok = record_queues(),
        ok = record_grpc_connections()
    end),
    _ = schedule_next_tick(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% elli Function Definitions
%% ------------------------------------------------------------------
handle(Req, _Args) ->
    handle(Req#req.method, elli_request:path(Req), Req).

handle('GET', [<<"metrics">>], _Req) ->
    {ok, [], prometheus_text_format:format()};
handle(_Verb, _Path, _Req) ->
    ignore.

handle_event(_Event, _Data, _Args) ->
    ok.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    ?UNIQUE_OFFER_ETS = ets:new(?UNIQUE_OFFER_ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true}
    ]),
    ok.

-spec declare_metrics() -> ok.
declare_metrics() ->
    %% type = frame type :: join | packet
    prometheus_counter:declare([
        {name, ?METRICS_UNIQUE_OFFER_COUNT},
        {help, "Unique frame count for NetID"},
        {labels, [net_id, type]}
    ]),

    %% type = frame type :: join | packet
    %% status = bought :: accepted | rejected
    prometheus_counter:declare([
        {name, ?METRICS_OFFER_COUNT},
        {help, "Offer count for NetID"},
        {labels, [net_id, type, status]}
    ]),

    %% type = frame type :: join | packet
    %% protocol :: udp | http_sync | http_async
    prometheus_counter:declare([
        {name, ?METRICS_PACKET_COUNT},
        {help, "Packet count for NetID"},
        {labels, [net_id, type, protocol]}
    ]),

    %% type = gwmp packet type :: push_ack | pull_ack
    %% status = received :: hit | miss
    prometheus_counter:declare([
        {name, ?METRICS_GWMP_COUNT},
        {help, "Semtech UDP acks for Gateway and NetID"},
        {labels, [net_id, type, status]}
    ]),

    %% Blockchain metrics
    prometheus_gauge:declare([
        {name, ?METRICS_DC_BALANCE},
        {help, "Account DC Balance"}
    ]),
    prometheus_gauge:declare([
        {name, ?METRICS_CHAIN_BLOCKS},
        {help, "Packet Purchaser's blockchain blocks"}
    ]),

    %% State channels
    prometheus_gauge:declare([
        {name, ?METRICS_SC_OPENED_COUNT},
        {help, "Opened State Channels count"}
    ]),
    prometheus_gauge:declare([
        {name, ?METRICS_SC_OVERSPENT_COUNT},
        {help, "Overspent State Channels count"}
    ]),
    prometheus_gauge:declare([
        {name, ?METRICS_SC_ACTIVE_COUNT},
        {help, "Active State Channels count"}
    ]),
    prometheus_gauge:declare([
        {name, ?METRICS_SC_ACTIVE_BALANCE},
        {help, "Active State Channels balance"}
    ]),
    prometheus_gauge:declare([
        {name, ?METRICS_SC_ACTIVE_ACTORS},
        {help, "Active State Channels actors"}
    ]),
    prometheus_counter:declare([
        {name, ?METRICS_SC_CLOSE_SUBMIT},
        {help, "State Channel Close Txn status"},
        {labels, [status]}
    ]),
    prometheus_gauge:declare([
        {name, ?METRICS_SC_CLOSE_CONFLICT},
        {help, "State Channels close with conflicts"}
    ]),

    %% Websocket
    prometheus_boolean:declare([
        {name, ?METRICS_WS_STATE},
        {help, "Websocket State"}
    ]),
    prometheus_counter:declare([
        {name, ?METRICS_WS_MSG_COUNT},
        {help, "Websocket packet messages prepared for sending"},
        {labels, [net_id]}
    ]),

    %% VM Statistics
    prometheus_gauge:declare([
        {name, ?METRICS_VM_CPU},
        {help, "Packet Purchaser CPU usage"},
        {labels, [cpu]}
    ]),
    prometheus_gauge:declare([
        {name, ?METRICS_VM_PROC_Q},
        {help, "Packet Purchaser process queue"},
        {labels, [name]}
    ]),
    prometheus_gauge:declare([
        {name, ?METRICS_VM_ETS_MEMORY},
        {help, "Packet Purchaser ets memory"},
        {labels, [name]}
    ]),

    %% GRPC
    prometheus_gauge:declare([
        {name, ?METRICS_GRPC_CONNECTION_COUNT},
        {help, "Number of active GRPC Connections"}
    ]),

    ok.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_WORKER_TICK_INTERVAL, self(), ?METRICS_WORKER_TICK).

record_dc_balance(PubKeyBin) ->
    case pp_utils:get_ledger() of
        fetching ->
            ok;
        Ledger ->
            case blockchain_ledger_v1:find_dc_entry(PubKeyBin, Ledger) of
                {error, _} ->
                    ok;
                {ok, Entry} ->
                    Balance = blockchain_ledger_data_credits_entry_v1:balance(Entry),
                    ok = ?MODULE:dcs(Balance)
            end
    end,
    ok.

record_chain_blocks() ->
    case pp_utils:get_chain() of
        fetching ->
            ok;
        Chain ->
            case blockchain:head_block(Chain) of
                {error, _} ->
                    ok;
                {ok, Block} ->
                    Now = erlang:system_time(seconds),
                    Time = blockchain_block:time(Block),
                    ok = ?MODULE:blocks(Now - Time)
            end
    end.

record_state_channels() ->
    case pp_utils:get_chain() of
        fetching ->
            ok;
        Chain ->
            {ok, Height} = blockchain:height(Chain),
            {OpenedCount, OverspentCount, _GettingCloseCount} = pp_sc_worker:counts(Height),

            ActiveSCs = maps:values(blockchain_state_channels_server:get_actives()),
            ActiveCount = erlang:length(ActiveSCs),

            {TotalDCLeft, TotalActors} = lists:foldl(
                fun({ActiveSC, _, _}, {DCs, Actors}) ->
                    Summaries = blockchain_state_channel_v1:summaries(ActiveSC),
                    TotalDC = blockchain_state_channel_v1:total_dcs(ActiveSC),
                    DCLeft = blockchain_state_channel_v1:amount(ActiveSC) - TotalDC,
                    %% If SC ran out of DC we should not be counted towards active metrics
                    case DCLeft of
                        0 ->
                            {DCs, Actors};
                        _ ->
                            {DCs + DCLeft, Actors + erlang:length(Summaries)}
                    end
                end,
                {0, 0},
                ActiveSCs
            ),

            ok = ?MODULE:state_channels(
                OpenedCount,
                OverspentCount,
                ActiveCount,
                TotalDCLeft,
                TotalActors
            )
    end,
    ok.

-spec record_vm_stats() -> ok.
record_vm_stats() ->
    [{_Mem, CPU}] = recon:node_stats_list(1, 1),
    lists:foreach(
        fun({Num, Usage}) ->
            _ = prometheus_gauge:set(?METRICS_VM_CPU, [Num], Usage)
        end,
        proplists:get_value(scheduler_usage, CPU, [])
    ),
    ok.

-spec record_ets() -> ok.
record_ets() ->
    lists:foreach(
        fun(ETS) ->
            Name = ets:info(ETS, name),
            case ets:info(ETS, memory) of
                undefined ->
                    ok;
                Memory ->
                    Bytes = Memory * erlang:system_info(wordsize),
                    case Bytes > 1000000 of
                        false -> ok;
                        true -> _ = prometheus_gauge:set(?METRICS_VM_ETS_MEMORY, [Name], Bytes)
                    end
            end
        end,
        ets:all()
    ),
    ok.

-spec record_grpc_connections() -> ok.
record_grpc_connections() ->
    Opts = application:get_env(grpcbox, listen_opts, #{}),
    PoolName = grpcbox_services_sup:pool_name(Opts),
    try
        Counts = acceptor_pool:count_children(PoolName),
        proplists:get_value(active, Counts)
    of
        Count ->
            _ = prometheus_gauge:set(?METRICS_GRPC_CONNECTION_COUNT, Count)
    catch
        _:_ ->
            lager:warning("no grpcbox acceptor named ~p", [PoolName]),
            _ = prometheus_gauge:set(?METRICS_GRPC_CONNECTION_COUNT, 0)
    end,
    ok.

-spec record_queues() -> ok.
record_queues() ->
    CurrentQs = lists:foldl(
        fun({Pid, Length, _Extra}, Acc) ->
            Name = get_pid_name(Pid),
            maps:put(Name, Length, Acc)
        end,
        #{},
        recon:proc_count(message_queue_len, 5)
    ),
    RecorderQs = lists:foldl(
        fun({[{"name", Name} | _], Length}, Acc) ->
            maps:put(Name, Length, Acc)
        end,
        #{},
        prometheus_gauge:values(default, ?METRICS_VM_PROC_Q)
    ),
    OldQs = maps:without(maps:keys(CurrentQs), RecorderQs),
    lists:foreach(
        fun({Name, _Length}) ->
            case name_to_pid(Name) of
                undefined ->
                    prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                Pid ->
                    case recon:info(Pid, message_queue_len) of
                        undefined ->
                            prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                        {message_queue_len, 0} ->
                            prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                        {message_queue_len, Length} ->
                            prometheus_gauge:set(?METRICS_VM_PROC_Q, [Name], Length)
                    end
            end
        end,
        maps:to_list(OldQs)
    ),
    NewQs = maps:without(maps:keys(OldQs), CurrentQs),
    Config = application:get_env(packet_purchaser, metrics, []),
    MinLength = proplists:get_value(record_queue_min_length, Config, 2000),
    lists:foreach(
        fun({Name, Length}) ->
            case Length > MinLength of
                true ->
                    _ = prometheus_gauge:set(?METRICS_VM_PROC_Q, [Name], Length);
                false ->
                    ok
            end
        end,
        maps:to_list(NewQs)
    ),
    ok.

-spec record_sc_close_conflict(
    Chain :: blockchain:blockchain(),
    BlockHash :: binary(),
    PubkeyBin :: libp2p_crypto:pubkey_bin()
) -> ok.
record_sc_close_conflict(Chain, BlockHash, PubkeyBin) ->
    case blockchain:get_block(BlockHash, Chain) of
        {error, _Reason} ->
            lager:error("failed to get block:~p ~p", [BlockHash, _Reason]);
        {ok, Block} ->
            Txns = lists:filter(
                fun(Txn) ->
                    case blockchain_txn:type(Txn) of
                        blockchain_txn_state_channel_close_v1 ->
                            SC = blockchain_txn_state_channel_close_v1:state_channel(Txn),
                            blockchain_state_channel_v1:owner(SC) == PubkeyBin andalso
                                blockchain_txn_state_channel_close_v1:conflicts_with(Txn) =/=
                                    undefined;
                        _ ->
                            false
                    end
                end,
                blockchain_block:transactions(Block)
            ),
            _ = prometheus_gauge:set(?METRICS_SC_CLOSE_CONFLICT, erlang:length(Txns)),
            ok
    end.

-spec get_pid_name(pid()) -> list().
get_pid_name(Pid) ->
    case recon:info(Pid, registered_name) of
        [] -> erlang:pid_to_list(Pid);
        {registered_name, Name} -> erlang:atom_to_list(Name);
        _Else -> erlang:pid_to_list(Pid)
    end.

-spec name_to_pid(list()) -> pid() | undefined.
name_to_pid(Name) ->
    case erlang:length(string:split(Name, ".", all)) == 3 of
        true ->
            erlang:list_to_pid(Name);
        false ->
            erlang:whereis(erlang:list_to_atom(Name))
    end.

-spec crawl_offers(Window :: non_neg_integer()) -> ok.
crawl_offers(Window) ->
    Now = erlang:system_time(millisecond) - Window,
    %% MS = ets:fun2ms(fun({Key, Time}) when Time < Now -> Key end),
    MS = [{{'$1', '$2'}, [{'<', '$2', {const, Now}}], ['$1']}],
    Expired = ets:select(?UNIQUE_OFFER_ETS, MS),
    lists:foreach(
        fun({NetID, _PHash, OfferType} = Key) ->
            true = ets:delete(?UNIQUE_OFFER_ETS, Key),
            ?MODULE:handle_unique_offer(NetID, OfferType)
        end,
        Expired
    ),
    ok.

-spec spawn_crawl_offers(Timer :: non_neg_integer(), Window :: non_neg_integer()) -> ok.
spawn_crawl_offers(Timer, Window) ->
    _ = erlang:spawn(fun() ->
        ok = timer:sleep(Timer),
        ok = crawl_offers(Window),
        ok = spawn_crawl_offers(Timer, Window)
    end),
    ok.
