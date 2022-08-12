-module(pp_udp_sup).

-behaviour(supervisor).

-include("packet_purchaser.hrl").

-include_lib("router_utils/include/semtech_udp.hrl").

%% API
-export([
    start_link/0,
    maybe_start_worker/2,
    lookup_worker/1
]).

%% Supervisor callbacks
-export([init/1]).

-define(WORKER(I), #{
    id => I,
    start => {I, start_link, []},
    restart => temporary,
    shutdown => 1000,
    type => worker,
    modules => [I]
}).

-define(FLAGS, #{
    strategy => simple_one_for_one,
    intensity => 3,
    period => 60
}).

-define(ETS, pp_udp_sup_ets).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

maybe_start_worker(WorkerKey, Args) ->
    maybe_start_worker(WorkerKey, Args, ?APP, ?UDP_WORKER, ?ETS ).

-spec maybe_start_worker(
    WorkerKey :: {PubKeyBin :: binary(), NetID :: non_neg_integer() | binary()},
    Args :: map() | {error, any()}, atom(), atom(), atom()
) -> {ok, pid()} | {error, any()} | {error, worker_not_started, any()}.
maybe_start_worker(_WorkerKey, {error, _} = Err, _, _, _) ->
    Err;
maybe_start_worker(WorkerKey, Args, AppName, UDPWorker, ETSTableName) ->
    case ets:lookup(ETSTableName, WorkerKey) of
        [] ->
            start_worker(WorkerKey, Args, AppName, UDPWorker, ETSTableName);
        [{WorkerKey, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    _ = ets:delete(ETSTableName, WorkerKey),
                    start_worker(WorkerKey, Args, AppName, UDPWorker, ETSTableName)
            end
    end.

lookup_worker(WorkerKey) ->
    lookup_worker(WorkerKey, ?ETS).

-spec lookup_worker({PubKeyBin :: binary(), NetID :: non_neg_integer() | binary()},
    atom() ) -> {ok, pid()} | {error, not_found}.
lookup_worker(WorkerKey, ETSTableName) ->
    case ets:lookup(ETSTableName, WorkerKey) of
        [] ->
            {error, not_found};
        [{WorkerKey, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> {error, not_found}
            end
    end.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    gwmp_udp_sup_init(?ETS, ?UDP_WORKER).

gwmp_udp_sup_init(ETSTableName, UDPWorker) ->
    ets:new(ETSTableName, [public, named_table, set]),
    {ok, {?FLAGS, [?WORKER(UDPWorker)]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_worker({binary(), non_neg_integer() | binary()}, map(),
    atom(), atom(), atom()) ->
    {ok, pid()} | {error, worker_not_started, any()}.
start_worker({PubKeyBin, NetID} = WorkerKey, Args, AppName, UDPWorker, ETSTableName) ->
    AppArgs = get_app_args(AppName, UDPWorker),
    ChildArgs = maps:merge(#{pubkeybin => PubKeyBin, net_id => NetID}, maps:merge(AppArgs, Args)),
    case supervisor:start_child(?MODULE, [ChildArgs]) of
        {error, Err} ->
            {error, worker_not_started, Err};
        {ok, Pid} = OK ->
            case ets:insert_new(?ETS, {WorkerKey, Pid}) of
                true ->
                    OK;
                false ->
                    supervisor:terminate_child(?MODULE, Pid),
                    maybe_start_worker(WorkerKey, Args, AppName, UDPWorker, ETSTableName)
            end
    end.

-spec get_app_args(atom(), atom()) -> map().
get_app_args(AppName, UDPWorker) ->
    AppArgs = maps:from_list(application:get_env(AppName, UDPWorker, [])),
    Port =
        case maps:get(port, AppArgs, 1700) of
            PortAsList when is_list(PortAsList) ->
                erlang:list_to_integer(PortAsList);
            P ->
                P
        end,
    maps:put(port, Port, AppArgs).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

get_app_args_test() ->
    application:set_env(?APP, ?UDP_WORKER, []),
    ?assertEqual(#{port => 1700}, get_app_args(?APP, ?UDP_WORKER)),
    application:set_env(?APP, ?UDP_WORKER, [{address, "127.0.0.1"}, {port, 1700}]),
    ?assertEqual(#{address => "127.0.0.1", port => 1700}, get_app_args(?APP, ?UDP_WORKER)),
    application:set_env(?APP, ?UDP_WORKER, [{address, "127.0.0.1"}, {port, "1700"}]),
    ?assertEqual(#{address => "127.0.0.1", port => 1700}, get_app_args(?APP, ?UDP_WORKER)),
    ok.

-endif.
