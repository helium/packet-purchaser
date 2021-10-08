-module(pp_udp_sup).

-behaviour(supervisor).

-include("packet_purchaser.hrl").

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

-spec maybe_start_worker(
    WorkerKey :: {PubKeyBin :: binary(), NetID :: non_neg_integer()},
    Args :: map() | {error, any()}
) -> {ok, pid()} | {error, any()}.
maybe_start_worker(_WorkerKey, {error, _} = Err) ->
    Err;
maybe_start_worker(WorkerKey, Args) ->
    case ets:lookup(?ETS, WorkerKey) of
        [] ->
            start_worker(WorkerKey, Args);
        [{WorkerKey, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    _ = ets:delete(?ETS, WorkerKey),
                    start_worker(WorkerKey, Args)
            end
    end.

-spec lookup_worker({PubKeyBin :: binary(), NetID :: non_neg_integer()}) ->
    {ok, pid()} | {error, not_found}.
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
    {ok, {?FLAGS, [?WORKER(?UDP_WORKER)]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_worker({binary(), non_neg_integer()}, map()) -> {ok, pid()} | {error, any()}.
start_worker({PubKeyBin, NetID} = WorkerKey, Args) ->
    AppArgs = get_app_args(),
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
                    maybe_start_worker(WorkerKey, Args)
            end
    end.

-spec get_app_args() -> map().
get_app_args() ->
    AppArgs = maps:from_list(application:get_env(?APP, ?UDP_WORKER, [])),
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
    ?assertEqual(#{port => 1700}, get_app_args()),
    application:set_env(?APP, ?UDP_WORKER, [{address, "127.0.0.1"}, {port, 1700}]),
    ?assertEqual(#{address => "127.0.0.1", port => 1700}, get_app_args()),
    application:set_env(?APP, ?UDP_WORKER, [{address, "127.0.0.1"}, {port, "1700"}]),
    ?assertEqual(#{address => "127.0.0.1", port => 1700}, get_app_args()),
    ok.

-endif.
