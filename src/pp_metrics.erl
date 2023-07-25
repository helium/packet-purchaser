-module(pp_metrics).

-behaviour(gen_server).
-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

-define(METRICS_UNIQUE_OFFER_COUNT, packet_purchaser_unique_offer_count).
-define(METRICS_OFFER_COUNT, packet_purchaser_offer_count).
-define(METRICS_PACKET_COUNT, packet_purchaser_packet_count).
-define(METRICS_PACKET_DOWN_COUNT, packet_purchaser_packet_down_count).

-define(METRICS_WS_STATE, packet_purchaser_ws_state).
-define(METRICS_WS_MSG_COUNT, packet_purchaser_ws_msg_count).

-define(METRICS_VM_CPU, packet_purchaser_vm_cpu).
-define(METRICS_VM_PROC_Q, packet_purchaser_vm_process_queue).
-define(METRICS_VM_ETS_MEMORY, packet_purchaser_vm_ets_memory).

-define(METRICS_GRPC_CONNECTION_COUNT, packet_purchaser_connection_count).
-define(METRICS_FUN_DURATION, packet_purchaser_function_duration).

-define(METRICS_PACKET_REPORT_HISTOGRAM, packet_purchaser_packet_report_histogram).

-define(METRICS_WORKER_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_WORKER_TICK, '__pp_metrics_tick').

%% gen_server API
-export([start_link/1]).

%% Prometheus API
-export([
    handle_unique_offer/3,
    handle_offer/4,
    handle_packet/4,
    handle_packet_down/2,
    %% Websocket
    ws_state/1,
    ws_send_msg/1,
    %% timing
    function_observe/2,
    %% packet reporting
    observe_packet_report/2
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

%% erlfmt-ignore
-define(VALID_NET_IDS, sets:from_list(
    lists:seq(16#000000, 16#0000FF) ++
    lists:seq(16#600000, 16#6000FF) ++
    lists:seq(16#C00000, 16#C000FF) ++
    lists:seq(16#E00000, 16#E000FF)
)).

-define(UNIQUE_OFFER_ETS, pp_metrics_unique_offer_ets).

-record(state, {}).

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

%% -------------------------------------------------------------------
%% Prometheus API Functions
%% -------------------------------------------------------------------

-spec handle_unique_offer(
    NetID :: non_neg_integer(),
    Type :: join | packet,
    Inc :: non_neg_integer()
) -> ok.
handle_unique_offer(NetID, Type, Inc) ->
    prometheus_counter:inc(?METRICS_UNIQUE_OFFER_COUNT, [clean_net_id(NetID), Type], Inc).

-spec handle_offer(
    NetID :: non_neg_integer(),
    OfferType :: join | packet,
    Action :: accepted | rejected,
    PHash :: binary()
) -> ok.
handle_offer(NetID, OfferType, Action, PHash) ->
    _ = ets:insert(?UNIQUE_OFFER_ETS, {{NetID, PHash, OfferType}, erlang:system_time(millisecond)}),
    prometheus_counter:inc(?METRICS_OFFER_COUNT, [clean_net_id(NetID), OfferType, Action]).

-spec handle_packet(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    NetID :: non_neg_integer(),
    PacketType :: join | packet,
    ProtocolType :: udp | http_sync | http_async
) -> ok.
handle_packet(_PubKeyBin, NetID, PacketType, ProtocolType) ->
    prometheus_counter:inc(?METRICS_PACKET_COUNT, [clean_net_id(NetID), PacketType, ProtocolType]).

-spec handle_packet_down(Status :: ok | error, Source :: udp | http) -> ok.
handle_packet_down(Status, Source) ->
    prometheus_counter:inc(?METRICS_PACKET_DOWN_COUNT, [Status, Source]).

-spec ws_state(boolean()) -> ok.
ws_state(State) ->
    catch prometheus_boolean:set(?METRICS_WS_STATE, State).

-spec ws_send_msg(NetID :: non_neg_integer()) -> ok.
ws_send_msg(NetID) ->
    prometheus_counter:inc(?METRICS_WS_MSG_COUNT, [NetID]).

-spec function_observe(atom(), non_neg_integer()) -> ok.
function_observe(Fun, Time) ->
    _ = prometheus_histogram:observe(?METRICS_FUN_DURATION, [Fun], Time),
    ok.

-spec clean_net_id(non_neg_integer()) -> unofficial_net_id | non_neg_integer().
clean_net_id(NetID) ->
    case sets:is_element(NetID, ?VALID_NET_IDS) of
        true -> NetID;
        false -> unofficial_net_id
    end.

-spec observe_packet_report(
    Status :: ok | error,
    Start :: non_neg_integer()
) -> ok.
observe_packet_report(Status, Start) ->
    prometheus_histogram:observe(
        ?METRICS_PACKET_REPORT_HISTOGRAM,
        [Status],
        erlang:system_time(millisecond) - Start
    ).

%% -------------------------------------------------------------------
%% gen_server Callbacks
%% -------------------------------------------------------------------

init(Args) ->
    ElliOpts = [
        {callback, ?MODULE},
        {port, proplists:get_value(port, Args, 3000)}
    ],
    {ok, _Pid} = elli:start_link(ElliOpts),

    Timer = proplists:get_value(unique_offers_cleanup_timer, Args, 10),
    Window = proplists:get_value(unique_offers_window, Args, 60),

    ok = declare_metrics(),
    ok = spawn_crawl_offers(timer:seconds(Timer), timer:seconds(Window)),
    _ = schedule_next_tick(),

    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(?METRICS_WORKER_TICK, State) ->
    lager:info("running metrics"),
    erlang:spawn(fun() ->
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

    %% status = downlink success :: ok | error
    %% source = protocol :: udp | http
    prometheus_counter:declare([
        {name, ?METRICS_PACKET_DOWN_COUNT},
        {help, "Packet Downlink count"},
        {labels, [status, source]}
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

    %% Function timing
    prometheus_histogram:declare([
        {name, ?METRICS_FUN_DURATION},
        {help, "Function duration"},
        {labels, [function]}
    ]),

    %% Packet Reporting
    prometheus_histogram:declare([
        {name, ?METRICS_PACKET_REPORT_HISTOGRAM},
        {help, "Packet Reports"},
        {labels, [status]}
    ]),

    ok.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_WORKER_TICK_INTERVAL, self(), ?METRICS_WORKER_TICK).

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

    %% Directly increment by the number we're about to delete by each key
    Counts = lists:foldl(
        fun({NetID, _Phash, OfferType}, Acc) ->
            Key = {NetID, OfferType},
            Acc#{Key => maps:get(Key, Acc, 0) + 1}
        end,
        #{},
        Expired
    ),
    maps:foreach(
        fun({NetID, OfferType}, Count) ->
            ?MODULE:handle_unique_offer(NetID, OfferType, Count)
        end,
        Counts
    ),

    %% Remove all accounted for
    lists:foreach(fun(Key) -> true = ets:delete(?UNIQUE_OFFER_ETS, Key) end, Expired),
    ok.

-spec spawn_crawl_offers(Timer :: non_neg_integer(), Window :: non_neg_integer()) -> ok.
spawn_crawl_offers(Timer, Window) ->
    _ = erlang:spawn(fun() ->
        ok = timer:sleep(Timer),
        ok = crawl_offers(Window),
        ok = spawn_crawl_offers(Timer, Window)
    end),
    ok.
