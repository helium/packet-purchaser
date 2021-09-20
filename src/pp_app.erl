%%%-------------------------------------------------------------------
%% @doc packet_purchaser public API
%% @end
%%%-------------------------------------------------------------------

-module(pp_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    case pp_sup:start_link() of
        {error, _} = Error ->
            Error;
        OK ->
            pp_cli_registry:register_cli(),
            OK
    end.

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
