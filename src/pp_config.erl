-module(pp_config).

-behaviour(gen_server).

%% gen_server API
-export([
    start_link/1,
    multi_buy_for_net_id/1,
    lookup_join/1,
    lookup_routing/1
]).

%% helper API
-export([
    init_ets/0,
    read_config/1,
    write_config_to_ets/1,
    reset_config/0,
    transform_config/1,
    load_config/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(JOIN_ETS, pp_config_join_ets).
-define(ROUTING_ETS, pp_config_routing_ets).
-define(DEFAULT_CONFIG, #{<<"net_id_aliases">> => #{}, <<"joins">> => [], <<"routing">> => []}).

-record(state, {
    filename :: string(),
    config :: map()
}).

-record(join, {
    net_id :: non_neg_integer(),
    app_eui :: non_neg_integer(),
    dev_eui :: '*' | non_neg_integer()
}).

-record(routing, {
    net_id :: non_neg_integer(),
    address :: binary(),
    port :: non_neg_integer(),
    multi_buy :: non_neg_integer()
}).

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Args], []).

multi_buy_for_net_id(NetID) ->
    case ets:lookup(?ROUTING_ETS, NetID) of
        [] ->
            {error, not_found};
        [#routing{multi_buy = MultiBuy}] ->
            {ok, MultiBuy}
    end.

lookup_join({eui, DevEUI, AppEUI}) ->
    %% ets:fun2ms(fun
    %%     (#join{app_eui = AppEUI, dev_eui = DevEUI, net_id=NetID}) when
    %%         AppEUI == 1234 andalso DevEUI == 2345
    %%     ->
    %%         NetID;
    %%     (#join{app_eui = AppEUI, dev_eui = '*', net_id=NetID}) when AppEUI == 1234 ->
    %%         NetID
    %% end).
    Spec = [
        {
            #join{net_id = '$1', app_eui = '$2', dev_eui = '$3'},
            [{'andalso', {'==', '$2', AppEUI}, {'==', '$3', DevEUI}}],
            ['$1']
        },
        {
            #join{net_id = '$1', app_eui = '$2', dev_eui = '*'},
            [{'==', '$2', AppEUI}],
            ['$1']
        }
    ],
    case ets:select(?JOIN_ETS, Spec) of
        [] ->
            undefined;
        [NetID] ->
            NetID
    end.

lookup_routing(NetID) ->
    case ets:lookup(?ROUTING_ETS, NetID) of
        [] ->
            {error, routing_not_found};
        [#routing{address = Address, port = Port}] ->
            {ok, #{address => erlang:binary_to_list(Address), port => Port}}
    end.

reset_config() ->
    true = ets:delete_all_objects(?JOIN_ETS),
    true = ets:delete_all_objects(?ROUTING_ETS),
    ok.

load_config(ConfigMap) ->
    ok = ?MODULE:reset_config(),
    Config = ?MODULE:transform_config(ConfigMap),
    ok = ?MODULE:write_config_to_ets(Config).

%% -------------------------------------------------------------------
%% gen_server Callbacks
%% -------------------------------------------------------------------

init([testing]) ->
    ok = ?MODULE:init_ets(),
    {ok, #state{filename = testing, config = #{}}};
init([Filename]) ->
    ok = ?MODULE:init_ets(),
    Config0 = ?MODULE:read_config(Filename),
    Config1 = ?MODULE:transform_config(Config0),
    ok = ?MODULE:write_config_to_ets(Config1),

    {ok, #state{
        filename = Filename,
        config = Config1
    }}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    ?JOIN_ETS = ets:new(?JOIN_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {keypos, #join.net_id}
    ]),
    ?ROUTING_ETS = ets:new(?ROUTING_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {keypos, #routing.net_id}
    ]),
    ok.

-spec read_config(string()) -> map().
read_config(Filename) ->
    {ok, Config} = file:read_file(Filename),
    jsx:decode(Config, [return_maps]).

-spec transform_config(map()) -> map().
transform_config(Config) ->
    #{
        <<"net_id_aliases">> := NetIdAliases0,
        <<"joins">> := Joins0,
        <<"routing">> := Routing0
    } = maps:merge(?DEFAULT_CONFIG, Config),

    NetIdAliases1 = maps:map(fun(_, Val) -> clean_base16(Val) end, NetIdAliases0),
    Joins1 = lists:map(fun(Entry) -> json_to_join_record(Entry, NetIdAliases1) end, Joins0),
    Routing1 = lists:map(fun(Entry) -> json_to_routing_record(Entry, NetIdAliases1) end, Routing0),

    #{
        net_id_aliases => NetIdAliases1,
        joins => Joins1,
        routing => Routing1
    }.

-spec write_config_to_ets(map()) -> ok.
write_config_to_ets(Config) ->
    #{joins := Joins, routing := Routing} = Config,
    true = ets:insert(?JOIN_ETS, Joins),
    true = ets:insert(?ROUTING_ETS, Routing),
    ok.

-spec json_to_join_record(map(), map()) -> #join{}.
json_to_join_record(Entry, NetIDAliases) ->
    NetID = resolve_net_id(Entry, NetIDAliases),
    #join{
        net_id = NetID,
        app_eui = clean_base16(maps:get(<<"app_eui">>, Entry)),
        dev_eui = clean_base16(maps:get(<<"dev_eui">>, Entry))
    }.

-spec json_to_routing_record(map(), map()) -> #routing{}.
json_to_routing_record(Entry, NetIDAliases) ->
    NetID = resolve_net_id(Entry, NetIDAliases),
    #routing{
        net_id = NetID,
        address = maps:get(<<"address">>, Entry),
        port = maps:get(<<"port">>, Entry),
        multi_buy = maps:get(<<"multi_buy">>, Entry, unlimited)
    }.

-spec resolve_net_id(map(), map()) -> non_neg_integer().
resolve_net_id(#{<<"net_id">> := NetID}, _) ->
    NetID;
resolve_net_id(#{<<"net_id_alias">> := Alias}, Aliases) ->
    maps:get(Alias, Aliases);
resolve_net_id(_, _) ->
    throw({bad_config, no_net_id}).

-spec clean_base16(binary()) -> '*' | non_neg_integer().
clean_base16(<<"*">>) -> '*';
clean_base16(<<"0x", Base16Number/binary>>) -> erlang:binary_to_integer(Base16Number, 16);
clean_base16(Bin) -> Bin.
%% clean_base16(_) -> throw(malformed_base16).
