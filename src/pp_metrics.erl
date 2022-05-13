-module(pp_metrics).

-behaviour(gen_server).
-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

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

-define(METRICS_WORKER_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_WORKER_TICK, '__pp_metrics_tick').

%% gen_server API
-export([start_link/0]).

%% Prometheus API
-export([
    handle_offer/5,
    handle_packet/4,
    %% GWMP
    pull_ack/2,
    pull_ack_missed/2,
    push_ack/2,
    push_ack_missed/2,
    %% Stats
    dcs/1,
    blocks/1,
    state_channels/5,
    state_channel_close/1,
    %% Websocket
    ws_state/1,
    ws_send_msg/1
]).

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

%% erlfmt-ignore
-define(VALID_NET_IDS, sets:from_list([
    16#000000, 16#000001, 16#000002, 16#000003, 16#000004, 16#000005, 16#000006, 16#000007,
    16#000008, 16#000009, 16#00000A, 16#00000B, 16#00000C, 16#00000D, 16#00000E, 16#00000F,
    16#000010, 16#000011, 16#000012, 16#000013, 16#000014, 16#000015, 16#000016, 16#000017,
    16#000018, 16#000019, 16#00001A, 16#00001B, 16#00001C, 16#00001D, 16#00001E, 16#00001F,
    16#000020, 16#000021, 16#000022, 16#000023, 16#000024, 16#000025, 16#000026, 16#000027,
    16#000028, 16#000029, 16#00002A, 16#00002B, 16#00002C, 16#00002D, 16#00002E, 16#00002F,
    16#000030, 16#000031, 16#000032, 16#000033, 16#000034, 16#000035, 16#000036, 16#000037,
    16#000038, 16#000039, 16#600000, 16#600001, 16#600002, 16#600003, 16#600004, 16#600005,
    16#600006, 16#600007, 16#600008, 16#600009, 16#60000A, 16#60000B, 16#60000C, 16#60000D,
    16#60000E, 16#60000F, 16#600010, 16#600011, 16#600012, 16#600013, 16#600014, 16#600015,
    16#600016, 16#600017, 16#600018, 16#600019, 16#60001A, 16#60001B, 16#60001C, 16#60001D,
    16#60001E, 16#60001F, 16#600020, 16#600021, 16#600022, 16#600023, 16#600024, 16#600025,
    16#600026, 16#600027, 16#600028, 16#600029, 16#60002A, 16#60002B, 16#60002C, 16#60002D,
    16#C00000, 16#C00001, 16#C00002, 16#C00003, 16#C00004, 16#C00005, 16#C00006, 16#C00007,
    16#C00008, 16#C00009, 16#C0000A, 16#C0000B, 16#C0000C, 16#C0000D, 16#C0000E, 16#C0000F,
    16#C00010, 16#C00011, 16#C00012, 16#C00013, 16#C00014, 16#C00015, 16#C00016, 16#C00017,
    16#C00018, 16#C00019, 16#C0001A, 16#C0001B, 16#C0001C, 16#C0001D, 16#C0001E, 16#C0001F,
    16#C00020, 16#C00021, 16#C00022, 16#C00023, 16#C00024, 16#C00025, 16#C00026, 16#C00027,
    16#C00028, 16#C00029, 16#C0002A, 16#C0002B, 16#C0002C, 16#C0002D, 16#C0002E, 16#C0002F,
    16#C00030, 16#C00031, 16#C00032, 16#C00033, 16#C00034, 16#C00035, 16#C00036, 16#C00037,
    16#C00038, 16#C00039, 16#C0003A, 16#C0003B, 16#C0003C, 16#C0003D, 16#C0003E, 16#C0003F,
    16#C00040, 16#C00041, 16#C00042, 16#C00043, 16#C00044, 16#C00045, 16#C00046, 16#C00047,
    16#C00048, 16#C00049, 16#C0004A, 16#C0004B, 16#C0004C, 16#C0004D, 16#C0004E, 16#C0004F,
    16#C00050, 16#C00051, 16#C00052, 16#C00053, 16#C00054,

    %% Extra
    16#E00020
])).

-record(state, {
    chain = undefined :: undefined | blockchain:blockchain(),
    pubkey_bin :: libp2p_crypto:pubkey_bin()
}).

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% -------------------------------------------------------------------
%% Prometheus API Functions
%% -------------------------------------------------------------------

-spec handle_offer(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    NetID :: non_neg_integer(),
    OfferType :: join | packet,
    Action :: accepted | rejected,
    PayloadSize :: non_neg_integer()
) -> ok.
handle_offer(_PubKeyBin, NetID, OfferType, Action, _PayloadSize) ->
    prometheus_counter:inc(?METRICS_OFFER_COUNT, [clean_net_id(NetID), OfferType, Action]).

-spec handle_packet(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    NetID :: non_neg_integer(),
    PacketType :: join | packet,
    ProtocolType :: udp | http_sync | http_async
) -> ok.
handle_packet(_PubKeyBin, NetID, PacketType, ProtocolType) ->
    prometheus_counter:inc(?METRICS_PACKET_COUNT, [clean_net_id(NetID), PacketType, ProtocolType]).

-spec push_ack(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
push_ack(_PubKeyBin, NetID) ->
    prometheus_counter:inc(?METRICS_GWMP_COUNT, [clean_net_id(NetID), push_ack, hit]).

-spec push_ack_missed(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
push_ack_missed(_PubKeyBin, NetID) ->
    prometheus_counter:inc(?METRICS_GWMP_COUNT, [clean_net_id(NetID), push_ack, miss]).

-spec pull_ack(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
pull_ack(_PubKeyBin, NetID) ->
    prometheus_counter:inc(?METRICS_GWMP_COUNT, [clean_net_id(NetID), pull_ack, hit]).

-spec pull_ack_missed(PubKeyBin :: libp2p_crypto:pubkey_bin(), NetID :: non_neg_integer()) -> ok.
pull_ack_missed(_PubKeyBin, NetID) ->
    prometheus_counter:inc(?METRICS_GWMP_COUNT, [clean_net_id(NetID), pull_ack, miss]).

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

-spec clean_net_id(non_neg_integer()) -> unofficial_net_id | non_neg_integer().
clean_net_id(NetID) ->
    case sets:is_element(NetID, ?VALID_NET_IDS) of
        true -> NetID;
        false -> unofficial_net_id
    end.

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

    ok = declare_metrics(),

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
        ok = record_queues()
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

-spec declare_metrics() -> ok.
declare_metrics() ->
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
    case erlang:length(string:split(Name, ".")) > 1 of
        true ->
            erlang:list_to_pid(Name);
        false ->
            erlang:whereis(erlang:list_to_atom(Name))
    end.
