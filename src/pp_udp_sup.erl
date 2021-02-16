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

-spec maybe_start_worker(binary(), map()) -> {ok, pid()} | {error, any()}.
maybe_start_worker(ID, Args) ->
    case ets:lookup(?ETS, ID) of
        [] ->
            start_worker(ID, Args);
        [{ID, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    _ = ets:delete(?ETS, ID),
                    start_worker(ID, Args)
            end
    end.

-spec lookup_worker(binary()) -> {ok, pid()} | {error, not_found}.
lookup_worker(ID) ->
    case ets:lookup(?ETS, ID) of
        [] ->
            {error, not_found};
        [{ID, Pid}] ->
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

-spec start_worker(binary(), map()) -> {ok, pid()} | {error, any()}.
start_worker(ID, Args) ->
    AppArgs = get_app_args(),
    ChildArgs = maps:merge(#{pubkeybin => ID}, maps:merge(AppArgs, Args)),
    case supervisor:start_child(?MODULE, [ChildArgs]) of
        {error, _Err} = Err ->
            Err;
        {ok, Pid} = OK ->
            case ets:insert_new(?ETS, {ID, Pid}) of
                true ->
                    OK;
                false ->
                    supervisor:terminate_child(?MODULE, Pid),
                    maybe_start_worker(ID, Args)
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
