%%%-------------------------------------------------------------------
%% @doc packet_purchaser top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(packet_purchaser_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(FLAGS, #{
    strategy => rest_for_one,
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
    {ok, _} = application:ensure_all_started(lager),
    lager:info("init ~p", [?SERVER]),
    ChildSpecs = [],
    {ok, {?FLAGS, ChildSpecs}}.

%% internal functions
