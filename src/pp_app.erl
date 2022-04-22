%%%-------------------------------------------------------------------
%% @doc packet_purchaser public API
%% @end
%%%-------------------------------------------------------------------

-module(pp_app).

-behaviour(application).

-define(LISTENER, pp_listener).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    ok = start_listener(),

    case pp_sup:start_link() of
        {error, _} = Error ->
            Error;
        OK ->
            pp_cli_registry:register_cli(),
            OK
    end.

%%--------------------------------------------------------------------
stop(_State) ->
    stop_listener(),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
start_listener() ->
    {ok, AuthMiddleware} = application:get_env(packet_purchaser, pp_auth_middleware),

    StartListenerFunc =
        case application:get_env(packet_purchaser, pp_listener_use_tls, false) of
            true -> fun cowboy:start_tls/3;
            false -> fun cowboy:start_clear/3
        end,

    {ok, ListenerProtocolOpts} = application:get_env(packet_purchaser, pp_listener_protocol_opts),

    Dispatch = cowboy_router:compile([{'_', [{"/hello", hello_handler, []}]}]),

    {ok, _} = StartListenerFunc(
        ?LISTENER,
        ListenerProtocolOpts,
        #{
            env => #{
                dispatch => Dispatch
            },
            middlewares => [
                cowboy_router,
                AuthMiddleware,
                cowboy_handler
            ]
        }
    ),
    ok.

stop_listener() ->
    cowboy:stop_listener(?LISTENER).
