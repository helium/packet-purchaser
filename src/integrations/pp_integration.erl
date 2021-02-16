-module(pp_integration).

-behavior(pp_integration_behavior).

-include("packet_purchaser.hrl").

-export([
    module/0,
    start_link/1,
    get_devices/0
]).

-spec module() -> atom().
module() ->
    {ok, Module} = application:get_env(?APP, ?MODULE),
    Module.

-spec start_link(Args :: map()) -> {ok, pid()} | ignore | {error, any()}.
start_link(Args) ->
    Mod = ?MODULE:module(),
    Mod:start_link(Args).

-spec get_devices() -> {ok, list(binary())} | {error, any()}.
get_devices() ->
    Mod = ?MODULE:module(),
    Mod:get_devices().
