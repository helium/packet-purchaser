%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser Integration Chirpstack ==
%% @end
%%%-------------------------------------------------------------------
-module(pp_integration_chirpstack).

-behavior(gen_server).
-behavior(pp_integration_behavior).

-include("packet_purchaser.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    get_devices/0
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-record(state, {
    endpoint :: binary(),
    app_id :: binary(),
    api_key :: binary(),
    app_eui :: binary()
}).

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec get_devices() -> {ok, list(binary())} | {error, any()}.
get_devices() ->
    gen_server:call(?SERVER, get_devices).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, #state{
        endpoint = erlang:list_to_binary(maps:get(endpoint, Args)),
        app_id = erlang:list_to_binary(maps:get(app_id, Args)),
        api_key = erlang:list_to_binary(maps:get(api_key, Args)),
        app_eui = pp_utils:hex_to_binary(erlang:list_to_binary(maps:get(app_eui, Args)))
    }}.

handle_call(
    get_devices,
    _From,
    #state{
        endpoint = Endpoint,
        app_id = AppID,
        api_key = APIKey,
        app_eui = AppEUI
    } = State
) ->
    Url = <<Endpoint/binary, "/api/devices?limit=9999999&applicationID=", AppID/binary>>,
    case
        hackney:get(
            Url,
            [
                {<<"Accept">>, <<"application/json">>},
                {<<"Grpc-Metadata-Authorization">>, <<"Bearer ", APIKey/binary>>}
            ],
            <<>>,
            [with_body]
        )
    of
        {ok, 200, _Headers, Body} ->
            Map = jsx:decode(Body, [return_maps]),
            Devices = maps:get(<<"result">>, Map, []),
            AppEUI = <<0, 0, 0, 0, 0, 0, 0, 0>>,
            Reply =
                {ok, [
                    <<(pp_utils:hex_to_binary(maps:get(<<"devEUI">>, D)))/binary, AppEUI/binary>>
                    || D <- Devices
                ]},
            {reply, Reply, State};
        {ok, StatusCode, _Headers, _Body} ->
            Reply = {error, StatusCode},
            {reply, Reply, State};
        {error, _Reason} = Reply ->
            {reply, Reply, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
