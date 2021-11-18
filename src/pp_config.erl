-module(pp_config).

-behaviour(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

%% gen_server API
-export([
    start_link/1,
    lookup_eui/1,
    lookup_devaddr/1
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

-define(EUI_ETS, pp_config_join_ets).
-define(DEVADDR_ETS, pp_config_routing_ets).

-record(state, {
    filename :: testing | string(),
    config :: map()
}).

-record(eui, {
    name :: undefined | binary(),
    net_id :: non_neg_integer(),
    address :: binary(),
    port :: non_neg_integer(),
    multi_buy :: unlimited | non_neg_integer(),
    disable_pull_data :: undefined | boolean(),
    dev_eui :: '*' | non_neg_integer(),
    app_eui :: non_neg_integer()
}).

-record(devaddr, {
    name :: undefined | binary(),
    net_id :: non_neg_integer(),
    address :: binary(),
    port :: non_neg_integer(),
    multi_buy :: unlimited | non_neg_integer(),
    disable_pull_data :: undefined | boolean()
}).

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Args], []).

-spec lookup_eui(EUI) -> {ok, map()} | {error, unmapped_eui} when
    EUI ::
        {eui, #eui_pb{}}
        | #eui_pb{}
        | {eui, DevEUI :: non_neg_integer(), AppEUI :: non_neg_integer()}.
lookup_eui({eui, #eui_pb{deveui = DevEUI, appeui = AppEUI}}) ->
    lookup_eui({eui, DevEUI, AppEUI});
lookup_eui(#eui_pb{deveui = DevEUI, appeui = AppEUI}) ->
    lookup_eui({eui, DevEUI, AppEUI});
lookup_eui({eui, DevEUI, AppEUI}) ->
    %% ets:fun2ms(fun(#eui{app_eui = AppEUI, dev_eui = DevEUI} = EUI) when
    %%     AppEUI == 1234 andalso (DevEUI == 2345 orelse DevEUI == '*')
    %% ->
    %%     EUI
    %% end).
    Spec = [
        {
            %% #eui{name = '_', net_id = '_', address = '_', port = '_', multi_buy = '_', dev_eui = '$1', app_eui = '$2'},
            {eui, '_', '_', '_', '_', '_', '$1', '$2'},
            [
                {
                    'andalso',
                    {'==', '$2', AppEUI},
                    {'orelse', {'==', '$1', DevEUI}, {'==', '$1', '*'}}
                }
            ],
            ['$_']
        }
    ],
    case ets:select(?EUI_ETS, Spec) of
        [] ->
            {error, unmapped_eui};
        [
            #eui{
                address = Address,
                port = Port,
                net_id = NetID,
                multi_buy = MultiBuy,
                disable_pull_data = DisablePullData
            }
        ] ->
            {ok, #{
                net_id => NetID,
                address => erlang:binary_to_list(Address),
                port => Port,
                multi_buy => MultiBuy,
                disable_pull_data => DisablePullData
            }}
    end.

-spec lookup_devaddr({devaddr, non_neg_integer()}) ->
    {ok, map()} | {error, routing_not_found | invalid_net_id_type}.
lookup_devaddr({devaddr, DevAddr}) ->
    case lorawan_devaddr:net_id(DevAddr) of
        {ok, NetID} ->
            case ets:lookup(?DEVADDR_ETS, NetID) of
                [] ->
                    {error, routing_not_found};
                [
                    #devaddr{
                        address = Address,
                        port = Port,
                        multi_buy = MultiBuy,
                        disable_pull_data = DisablePullData
                    }
                ] ->
                    {ok, #{
                        net_id => NetID,
                        address => erlang:binary_to_list(Address),
                        port => Port,
                        multi_buy => MultiBuy,
                        disable_pull_data => DisablePullData
                    }}
            end;
        Err ->
            Err
    end.

-spec reset_config() -> ok.
reset_config() ->
    true = ets:delete_all_objects(?EUI_ETS),
    true = ets:delete_all_objects(?DEVADDR_ETS),
    ok.

-spec load_config(list(map())) -> ok.
load_config(ConfigList) ->
    ok = ?MODULE:reset_config(),
    Config = ?MODULE:transform_config(ConfigList),
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
    ?EUI_ETS = ets:new(?EUI_ETS, [
        public,
        named_table,
        bag,
        {read_concurrency, true}
    ]),
    ?DEVADDR_ETS = ets:new(?DEVADDR_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {keypos, #devaddr.net_id}
    ]),
    ok.

-spec read_config(string()) -> list(map()).
read_config(Filename) ->
    {ok, Config} = file:read_file(Filename),
    jsx:decode(Config, [return_maps]).

-spec transform_config(list()) -> map().
transform_config(ConfigList0) ->
    ConfigList1 = lists:flatten(
        lists:map(
            fun transform_config_entry/1,
            ConfigList0
        )
    ),
    #{
        joins => proplists:append_values(joins, ConfigList1),
        routing => proplists:append_values(routing, ConfigList1)
    }.

-spec transform_config_entry(Entry :: map()) -> proplists:proplist().
transform_config_entry(Entry) ->
    #{
        <<"net_id">> := NetID,
        <<"address">> := Address,
        <<"port">> := Port
    } = Entry,
    Name = maps:get(<<"name">>, Entry, <<"no_name">>),
    MultiBuy = maps:get(<<"multi_buy">>, Entry, unlimited),
    Joins = maps:get(<<"joins">>, Entry, []),

    JoinRecords = lists:map(
        fun(#{<<"dev_eui">> := DevEUI, <<"app_eui">> := AppEUI}) ->
            #eui{
                name = Name,
                net_id = clean_config_value(NetID),
                address = Address,
                port = Port,
                multi_buy = MultiBuy,
                dev_eui = clean_config_value(DevEUI),
                app_eui = clean_config_value(AppEUI)
            }
        end,
        Joins
    ),
    Routing = #devaddr{
        name = Name,
        net_id = clean_config_value(NetID),
        address = Address,
        port = Port,
        multi_buy = MultiBuy
    },
    [{joins, JoinRecords}, {routing, Routing}].

-spec write_config_to_ets(map()) -> ok.
write_config_to_ets(Config) ->
    #{joins := Joins, routing := Routing} = Config,
    true = ets:insert(?EUI_ETS, Joins),
    true = ets:insert(?DEVADDR_ETS, Routing),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Valid config values include:
%%   "*"        :: wildcard
%%   "0x123abc" :: hex number
%%   1337       :: integer
%%
%% @end
%%--------------------------------------------------------------------
-spec clean_config_value(binary()) -> '*' | non_neg_integer().
clean_config_value(Num) when erlang:is_integer(Num) -> Num;
clean_config_value(<<"*">>) -> '*';
clean_config_value(<<"0x", Base16Number/binary>>) -> erlang:binary_to_integer(Base16Number, 16);
clean_config_value(Bin) -> Bin.
%% clean_base16(_) -> throw(malformed_base16).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

join_eui_to_net_id_test() ->
    {ok, _} = pp_config:start_link(testing),
    Dev1 = 7,
    App1 = 13,
    Dev2 = 13,
    App2 = 17,
    EUI1 = #eui_pb{deveui = Dev1, appeui = App1},
    EUI2 = #eui_pb{deveui = Dev2, appeui = App2},

    NoneMapped = [],
    OneMapped = [
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [#{<<"app_eui">> => App1, <<"dev_eui">> => Dev1}]
        }
    ],
    BothMapped = [
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [#{<<"app_eui">> => App1, <<"dev_eui">> => Dev1}]
        },
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => 99,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [#{<<"app_eui">> => App2, <<"dev_eui">> => Dev2}]
        }
    ],
    WildcardMapped = [
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => 2,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [#{<<"app_eui">> => App1, <<"dev_eui">> => <<"*">>}]
        },
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => 99,
            <<"address">> => <<>>,
            <<"port">> => 1337,
            <<"joins">> => [#{<<"app_eui">> => App2, <<"dev_eui">> => <<"*">>}]
        }
    ],

    ok = pp_config:load_config(NoneMapped),
    ?assertMatch({error, _}, ?MODULE:lookup_eui(EUI1), "Empty mapping, no joins"),

    ok = pp_config:load_config(OneMapped),
    ?assertMatch({ok, _}, ?MODULE:lookup_eui(EUI1), "One EUI mapping, this one"),
    ?assertMatch({error, _}, ?MODULE:lookup_eui(EUI2), "One EUI mapping, not this one"),

    ok = pp_config:load_config(BothMapped),
    ?assertMatch({ok, _}, ?MODULE:lookup_eui(EUI1), "All EUI Mapped 1"),
    ?assertMatch({ok, _}, ?MODULE:lookup_eui(EUI2), "All EUI Mapped 2"),

    ok = pp_config:load_config(WildcardMapped),
    ?assertMatch({ok, _}, ?MODULE:lookup_eui(EUI1), "Wildcard EUI Mapped 1"),
    ?assertMatch(
        {ok, _},
        ?MODULE:lookup_eui(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = App1
            }
        ),
        "Wildcard random device EUI Mapped 1"
    ),
    ?assertMatch({ok, _}, ?MODULE:lookup_eui(EUI2), "Wildcard EUI Mapped 2"),
    ?assertMatch(
        {ok, _},
        ?MODULE:lookup_eui(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = App2
            }
        ),
        "Wildcard random device EUI Mapped 2"
    ),
    ?assertMatch(
        {error, _},
        ?MODULE:lookup_eui(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = rand:uniform(trunc(math:pow(2, 64) - 1000)) + 1000
            }
        ),
        "Wildcard random device EUI and unknown join eui no joins"
    ),

    ok.

-endif.
