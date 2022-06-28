-module(pp_packet_sup).

-behaviour(supervisor).

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

-define(ETS, pp_packet_sup_ets).

-type worker_key() :: binary().
-type worker_args() :: #{
    routing := pp_config:eui() | pp_config:devaddr(),
    phash := binary()
}.

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec maybe_start_worker(
    WorkerKey :: worker_key(),
    WorkerArgs :: worker_args()
) -> {ok, pid()} | {error, any()} .
maybe_start_worker(WorkerKey, WorkerArgs) ->
    case ets:lookup(?ETS, WorkerKey) of
        [] ->
            start_worker(WorkerKey, WorkerArgs);
        [{WorkerKey, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    _ = ets:delete(?ETS, WorkerKey),
                    start_worker(WorkerKey, WorkerArgs)
            end
    end.

-spec lookup_worker(WorkerKey :: worker_key()) -> {ok, pid()} | {error, not_found}.
lookup_worker(WorkerKey) ->
    case ets:lookup(?ETS, WorkerKey) of
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
    ets:new(?ETS, [public, named_table, set]),
    {ok, {?FLAGS, [?WORKER(pp_packet_worker)]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_worker(WorkerKey :: worker_key(), WorkerArgs :: worker_args()) ->
    {ok, pid()} | {error, any()}.
start_worker(WorkerKey, WorkerArgs) ->
    Configs = pp_config:lookup(maps:get(routing, WorkerArgs)),
    case supervisor:start_child(?MODULE, [WorkerArgs#{configs => Configs}]) of
        {error, Err} ->
            {error, {worker_not_started, Err}};
        {ok, Pid} = OK ->
            case ets:insert_new(?ETS, {WorkerKey, Pid}) of
                true ->
                    OK;
                false ->
                    supervisor:terminate_child(?MODULE, Pid),
                    maybe_start_worker(WorkerKey, WorkerArgs)
            end
    end.
