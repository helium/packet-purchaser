-module(pp_udp_sup).

-behaviour(supervisor).

-include("packet_purchaser.hrl").

-include_lib("router_utils/include/semtech_udp.hrl").
-include_lib("router_utils/include/gwmp_udp_worker_sup.hrl").

%% API
-export([
    start_link/0,
    maybe_start_worker/2,
    lookup_worker/1
]).

%% Supervisor callbacks
-export([init/1]).

-define(ETS, pp_udp_sup_ets).

-define(FLAGS, #{
    strategy => simple_one_for_one,
    intensity => 3,
    period => 60
}).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

maybe_start_worker(WorkerKey, Args) ->
    gwmp_udp_worker_sup_utils:maybe_start_worker(WorkerKey, Args, ?APP, ?UDP_WORKER, ?ETS, ?MODULE).

lookup_worker(WorkerKey) ->
    gwmp_udp_worker_sup_utils:lookup_worker(WorkerKey, ?ETS).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    gwmp_udp_worker_sup_utils:gwmp_udp_sup_init(?ETS, ?UDP_WORKER, ?FLAGS).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

get_app_args_test() ->
    application:set_env(?APP, ?UDP_WORKER, []),
    ?assertEqual(#{port => 1700}, gwmp_udp_worker_sup_utils:get_app_args(?APP, ?UDP_WORKER)),
    application:set_env(?APP, ?UDP_WORKER, [{address, "127.0.0.1"}, {port, 1700}]),
    ?assertEqual(#{address => "127.0.0.1", port => 1700}, gwmp_udp_worker_sup_utils:get_app_args(?APP, ?UDP_WORKER)),
    application:set_env(?APP, ?UDP_WORKER, [{address, "127.0.0.1"}, {port, "1700"}]),
    ?assertEqual(#{address => "127.0.0.1", port => 1700}, gwmp_udp_worker_sup_utils:get_app_args(?APP, ?UDP_WORKER)),
    ok.

-endif.
