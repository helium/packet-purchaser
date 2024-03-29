-module(pp_console_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

-define(FLAGS, #{
    strategy => one_for_one,
    intensity => 1,
    period => 5
}).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    ConsoleAPIConfig = maps:from_list(application:get_env(packet_purchaser, pp_console_api, [])),
    {ok,
        {?FLAGS, [
            ?WORKER(pp_console_ws_worker, [ConsoleAPIConfig]),
            ?WORKER(pp_console_ws_manager, [ConsoleAPIConfig])
        ]}}.

%%====================================================================
%% Internal functions
%%====================================================================
