-module(pp_config).

-behaviour(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("http_protocol.hrl").

%% gen_server API
-export([
    start_link/1,
    lookup/1,
    lookup_eui/1,
    lookup_devaddr/1,
    %% http
    lookup_netid/1,
    %% UDP Cache
    insert_udp_worker/2,
    delete_udp_worker/1,
    %% Purchasing
    start_buying/1,
    stop_buying/1,
    change_http_protocol_version/2
]).

%% helper API
-export([
    init_ets/0,
    read_config/1,
    write_config_to_ets/1,
    reset_config/0,
    transform_config/1,
    load_config/1,
    get_config/0,
    reload_config_from_file/1,
    reload_config_from_file/0,
    write_config_to_disk/1
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

%% Record accessors
-export([
    net_id/1,
    name/1,
    multi_buy/1,
    buying_active/1
]).

%% downlink response ets
-export([
    insert_transaction_id/3,
    lookup_transaction_id/1
]).

%% Websocket API
-export([ws_update_config/1]).

-define(EUI_ETS, pp_config_join_ets).
-define(DEVADDR_ETS, pp_config_routing_ets).
-define(UDP_WORKER_ETS, pp_config_udp_worker_ets).
-define(TRANSACTION_ETS, pp_config_transaction_ets).

-define(DEFAULT_PROTOCOL, <<"udp">>).

-record(state, {
    filename :: testing | string()
}).

-record(udp_protocol, {
    address :: string(),
    port :: non_neg_integer()
}).

-type protocol() :: not_configured | #http_protocol{} | #udp_protocol{}.

-record(eui, {
    name :: undefined | binary(),
    net_id :: non_neg_integer(),
    multi_buy :: unlimited | non_neg_integer(),
    dev_eui :: '*' | non_neg_integer(),
    app_eui :: non_neg_integer(),
    buying_active = true :: boolean(),
    protocol :: protocol(),
    %% TODO remove eventually
    disable_pull_data = false :: boolean(),
    ignore_disable = false :: boolean()
}).

-record(devaddr, {
    name :: undefined | binary(),
    net_id :: non_neg_integer(),
    multi_buy :: unlimited | non_neg_integer(),
    buying_active = true :: boolean(),
    addr :: {single, integer()} | {range, integer(), integer()},
    protocol :: protocol(),
    %% TODO remove eventually
    disable_pull_data = false :: boolean(),
    ignore_disable = false :: boolean()
}).

-type config() :: #{joins := [#eui{}], routing := [#devaddr{}]}.

-type eui() ::
    {eui, #eui_pb{}}
    | #eui_pb{}
    | {eui, DevEUI :: non_neg_integer(), AppEUI :: non_neg_integer()}.
-type devaddr() :: {devaddr, DevAddr :: non_neg_integer()}.

%% -------------------------------------------------------------------
%% API Functions
%% -------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Args], []).

-spec lookup(eui() | devaddr()) ->
    {ok, list(map())}
    | {error, {buying_inactive, NetID :: integer()}}
    | {error, {not_configured, NetID :: integer()}}
    | {error, unmapped_eui}
    | {error, routing_not_found}
    | {error, invalid_netid_type}.
lookup({devaddr, _} = DevAddr) -> lookup_devaddr(DevAddr);
lookup(EUI) -> lookup_eui(EUI).

-spec lookup_eui(eui()) ->
    {ok, list(map())}
    | {error, {buying_inactive, NetID :: integer()}}
    | {error, {not_configured, NetID :: integer()}}
    | {error, unmapped_eui}.
lookup_eui({eui, #eui_pb{deveui = DevEUI, appeui = AppEUI}}) ->
    lookup_eui({eui, DevEUI, AppEUI});
lookup_eui(#eui_pb{deveui = DevEUI, appeui = AppEUI}) ->
    lookup_eui({eui, DevEUI, AppEUI});
lookup_eui({eui, DevEUI, AppEUI}) ->
    Spec = ets:fun2ms(fun(#eui{app_eui = InnerAppEUI, dev_eui = InnerDevEUI} = EUI) when
        AppEUI == InnerAppEUI andalso
            (DevEUI == InnerDevEUI orelse InnerDevEUI == '*')
    ->
        EUI
    end),
    Res = ets:select(?EUI_ETS, Spec),
    ct:print("Looking for ~p , ~p", [DevEUI, AppEUI]),
    ct:print("Found: ~p", [Res]),
    case Res of
        [] ->
            {error, unmapped_eui};
        [#eui{protocol = not_configured, net_id = NetID}] ->
            {error, {not_configured, NetID}};
        [#eui{buying_active = false, net_id = NetID}] ->
            {error, {buying_inactive, NetID}};
        Matches0 ->
            Matches1 = lists:filtermap(
                fun
                    (#eui{buying_active = false}) ->
                        false;
                    (#eui{protocol = not_configured}) ->
                        false;
                    (
                        #eui{
                            protocol = Protocol,
                            net_id = NetID,
                            multi_buy = MultiBuy,
                            disable_pull_data = DisablePullData
                        }
                    ) ->
                        {true,
                            maybe_clean_udp(#{
                                protocol => Protocol,
                                net_id => NetID,
                                multi_buy => MultiBuy,
                                disable_pull_data => DisablePullData
                            })}
                end,
                Matches0
            ),
            Matches2 = dedupe_udp_matches(Matches1),
            {ok, Matches2}
    end.

-spec lookup_devaddr({devaddr, non_neg_integer()}) ->
    {ok, list(map())}
    | {error, {buying_inactive, NetID :: integer()}}
    | {error, {not_configured, NetID :: integer()}}
    | {error, routing_not_found}
    | {error, invalid_netid_type}.
lookup_devaddr({devaddr, DevAddr}) ->
    case pp_lorawan:parse_netid(DevAddr) of
        {ok, NetID} ->
            Spec = ets:fun2ms(fun(
                #devaddr{
                    net_id = Key,
                    addr = {range, Lower, Upper}
                } = V
            ) when Key == NetID andalso Lower =< DevAddr andalso DevAddr =< Upper ->
                V
            end),
            Found = ets:select(?DEVADDR_ETS, Spec),
            case Found of
                [] ->
                    {error, routing_not_found};
                [#devaddr{protocol = not_configured, net_id = NetID}] ->
                    {error, {not_configured, NetID}};
                [#devaddr{buying_active = false, net_id = NetID}] ->
                    {error, {buying_inactive, NetID}};
                [
                    #devaddr{
                        protocol = Protocol,
                        multi_buy = MultiBuy,
                        disable_pull_data = DisablePullData
                    }
                ] ->
                    {ok, [
                        maybe_clean_udp(#{
                            protocol => Protocol,
                            net_id => NetID,
                            multi_buy => MultiBuy,
                            disable_pull_data => DisablePullData
                        })
                    ]}
            end;
        Err ->
            Err
    end.

-spec lookup_netid(NetID :: non_neg_integer()) -> {ok, map()} | {error, routing_not_found}.
lookup_netid(NetID) ->
    case ets:lookup(?DEVADDR_ETS, NetID) of
        [] ->
            {error, routing_not_found};
        [
            #devaddr{
                protocol = Protocol,
                multi_buy = MultiBuy,
                disable_pull_data = DisablePullData
            }
        ] ->
            {ok, #{
                protocol => Protocol,
                net_id => NetID,
                multi_buy => MultiBuy,
                disable_pull_data => DisablePullData
            }}
    end.

-spec reset_config() -> ok.
reset_config() ->
    true = ets:delete_all_objects(?EUI_ETS),
    true = ets:delete_all_objects(?DEVADDR_ETS),
    ok.

-spec load_config(list(map())) -> ok.
load_config(ConfigList) ->
    Entries = pp_config_v2:parse_config(ConfigList),

    {DevAddrs, Joins} = lists:partition(
        fun
            (#devaddr{}) -> true;
            (_) -> false
        end,
        Entries
    ),
    ok = ?MODULE:reset_config(),
    true = ets:insert(?EUI_ETS, Joins),
    true = ets:insert(?DEVADDR_ETS, DevAddrs),

    ct:print("~p", [ets:tab2list(?EUI_ETS)]),

    %% {ok, PrevConfig} = ?MODULE:get_config(),
    %% Config = ?MODULE:transform_config(ConfigList),

    %% ok = ?MODULE:reset_config(),

    %% #{joins := Joins, routing := Routing} = Config,
    %% true = ets:insert(?EUI_ETS, Joins),
    %% true = ets:insert(?DEVADDR_ETS, Routing),
    %% ok.
    %% %% ok = ?MODULE:write_config_to_ets(Config),

    %% #{routing := PrevRouting} = PrevConfig,
    %% #{routing := CurrRouting} = Config,

    %% ok = lists:foreach(
    %%     fun(#devaddr{net_id = NetID, protocol = Protocol} = CurrEntry) ->
    %%         case lists:keyfind(NetID, #devaddr.net_id, PrevRouting) of
    %%             %% Added
    %%             false ->
    %%                 ok;
    %%             CurrEntry ->
    %%                 %% Unchanged
    %%                 ok;
    %%             _ExistingEntry ->
    %%                 %% Updated
    %%                 ok = update_udp_workers(NetID, Protocol)
    %%         end
    %%     end,
    %%     CurrRouting
    %% ),

    ok.

-spec reload_config_from_file(Filename :: string()) -> ok.
reload_config_from_file(Filename) ->
    NewConfig = ?MODULE:read_config(Filename),
    ?MODULE:load_config(NewConfig).

-spec reload_config_from_file() -> ok.
reload_config_from_file() ->
    gen_server:call(?MODULE, reload_config_from_file).

-spec ws_update_config(list(map())) -> ok.
ws_update_config(ConfigList) ->
    ?MODULE:load_config(ConfigList).

-spec get_config() -> {ok, config()}.
get_config() ->
    {ok, #{
        joins => ets:tab2list(?EUI_ETS),
        routing => ets:tab2list(?DEVADDR_ETS)
    }}.

-spec insert_udp_worker(NetID :: integer(), UDPPid :: pid()) -> ok.
insert_udp_worker(NetID, Pid) ->
    true = ets:insert(?UDP_WORKER_ETS, {NetID, Pid}),
    ok.

-spec delete_udp_worker(Pid :: pid()) -> ok.
delete_udp_worker(Pid) ->
    %% ets:fun2ms(fun({_NetID, UDPPid}) when UDPPid == PID -> true end).
    Spec = [{{'$1', '$2'}, [{'==', '$2', Pid}], [true]}],
    %% There should only be 1 Pid for net_id
    1 = ets:select_delete(?UDP_WORKER_ETS, Spec),
    ok.

%% -spec lookup_udp_workers_for_net_id(NetID :: integer()) -> list(pid()).
%% lookup_udp_workers_for_net_id(NetID) ->
%%     [P || {_, P} <- ets:lookup(?UDP_WORKER_ETS, NetID)].

%% -spec update_udp_workers(NetID :: integer(), Protocol :: udp_protocol() | http_protocol()) -> ok.
%% update_udp_workers(NetID, Protocol) ->
%%     [
%%         pp_udp_worker:update_address(WorkerPid, Protocol)
%%         || WorkerPid <- lookup_udp_workers_for_net_id(NetID)
%%     ],
%%     ok.

-spec start_buying(NetIDs :: [integer()]) -> ok | {error, any()}.
start_buying([]) ->
    ok;
start_buying([NetID | NetIDS]) ->
    ok = update_buying_devaddr(NetID, true),
    ok = update_buying_eui(NetID, true),
    ?MODULE:start_buying(NetIDS).

-spec stop_buying(NetIDs :: [integer()]) -> ok | {error, any()}.
stop_buying([]) ->
    ok;
stop_buying([NetID | NetIDS]) ->
    ok = update_buying_devaddr(NetID, false),
    ok = update_buying_eui(NetID, false),
    ?MODULE:stop_buying(NetIDS).

-spec change_http_protocol_version(integer(), protocol_version()) -> ok | {error, any()}.
change_http_protocol_version(NetID, ProtocolVersion) ->
    case lists:member(ProtocolVersion, [pv_1_0, pv_1_1]) of
        false ->
            {error, {invalid_version, ProtocolVersion}};
        true ->
            ok = update_devaddr_http_protocol_version(NetID, ProtocolVersion),
            ok = update_eui_http_protocol_version(NetID, ProtocolVersion)
    end.

%% -------------------------------------------------------------------
%% gen_server Callbacks
%% -------------------------------------------------------------------

init([testing]) ->
    {ok, #state{filename = testing}};
init([Filename]) ->
    Config0 = ?MODULE:read_config(Filename),
    Config1 = ?MODULE:transform_config(Config0),
    ok = ?MODULE:write_config_to_ets(Config1),
    {ok, #state{filename = Filename}}.

handle_call(reload_config_from_file, _From, #state{filename = Filename} = State) ->
    ok = reload_config_from_file(Filename),
    {reply, ok, State};
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

%% -------------------------------------------------------------------
%% Accessing Functions
%% -------------------------------------------------------------------
-spec net_id(#devaddr{}) -> non_neg_integer().
net_id(#devaddr{net_id = NetID}) ->
    NetID.

-spec name(#devaddr{}) -> binary().
name(#devaddr{name = Name}) ->
    Name.

-spec multi_buy(#devaddr{}) -> unlimited | non_neg_integer().
multi_buy(#devaddr{multi_buy = MB}) ->
    MB.

-spec buying_active(#devaddr{}) -> boolean().
buying_active(#devaddr{buying_active = Active}) ->
    Active.

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
        bag,
        {read_concurrency, true}
    ]),
    ?UDP_WORKER_ETS = ets:new(?UDP_WORKER_ETS, [
        public,
        named_table,
        bag,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ?TRANSACTION_ETS = ets:new(?TRANSACTION_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ok.

insert_transaction_id(TransactionID, Endpoint, FlowType) ->
    true = ets:insert(?TRANSACTION_ETS, {TransactionID, Endpoint, FlowType}),
    ok.

lookup_transaction_id(TransactionID) ->
    case ets:lookup(?TRANSACTION_ETS, TransactionID) of
        [] -> {error, routing_not_found};
        [{_, Endpoint, FlowType}] -> {ok, Endpoint, FlowType}
    end.

-spec update_buying_devaddr(NetID :: integer(), BuyingActive :: boolean()) -> ok.
update_buying_devaddr(NetID, BuyingActive) ->
    %% There are potentially many DevAddrs per NetID. `ets:select_replace/2'
    %% requires you keep the key intact, in a bag table the whole record is
    %% considered as part of the key. So the current solution is to grab
    %% everything we know of, delete it all, update the items for the NetID in
    %% question and reinsert everything.
    AllDevAddrs = ets:tab2list(?DEVADDR_ETS),
    NewDevAddrs = lists:map(
        fun
            (#devaddr{ignore_disable = true} = Val) ->
                Val;
            (#devaddr{net_id = Key} = Val) when Key == NetID ->
                Val#devaddr{buying_active = BuyingActive};
            (Val) ->
                Val
        end,
        AllDevAddrs
    ),

    true = ets:delete_all_objects(?DEVADDR_ETS),
    true = ets:insert(?DEVADDR_ETS, NewDevAddrs),
    ok.

-spec update_buying_eui(NetID :: integer(), BuyingActive :: boolean()) -> ok.
update_buying_eui(NetID, BuyingActive) ->
    %% There are potentially many EUIs per NetID. `ets:select_replace/2'
    %% requires you keep the key intact, in a bag table the whole record is
    %% considered as part of the key. So the current solution is to grab
    %% everything we know of, delete it all, update the items for the NetID in
    %% question and reinsert everything.
    AllEuis = ets:tab2list(?EUI_ETS),
    NewEUIs = lists:map(
        fun
            %% TODO
            (#eui{ignore_disable = true} = Val) -> Val;
            (#eui{net_id = Key} = Val) when Key == NetID -> Val#eui{buying_active = BuyingActive};
            (Val) -> Val
        end,
        AllEuis
    ),
    true = ets:delete_all_objects(?EUI_ETS),
    true = ets:insert(?EUI_ETS, NewEUIs),
    ok.

-spec update_devaddr_http_protocol_version(
    NetID :: integer(),
    ProtocolVersion :: protocol_version()
) -> ok.
update_devaddr_http_protocol_version(NetID, ProtocolVersion) ->
    %% There are potentially many DevAddrs per NetID. `ets:select_replace/2'
    %% requires you keep the key intact, in a bag table the whole record is
    %% considered as part of the key. So the current solution is to grab
    %% everything we know of, delete it all, update the items for the NetID in
    %% question and reinsert everything.
    AllDevAddrs = ets:tab2list(?DEVADDR_ETS),
    NewDevAddrs = lists:map(
        fun
            (#devaddr{net_id = Key, protocol = #http_protocol{} = Protocol} = Val) when
                Key == NetID
            ->
                Val#devaddr{protocol = Protocol#http_protocol{protocol_version = ProtocolVersion}};
            (Val) ->
                Val
        end,
        AllDevAddrs
    ),

    true = ets:delete_all_objects(?DEVADDR_ETS),
    true = ets:insert(?DEVADDR_ETS, NewDevAddrs),
    ok.

-spec update_eui_http_protocol_version(
    NetID :: integer(),
    ProtocolVersion :: protocol_version()
) -> ok.
update_eui_http_protocol_version(NetID, ProtocolVersion) ->
    AllEUIs = ets:tab2list(?EUI_ETS),
    NewEUIs = lists:map(
        fun
            (#eui{net_id = Key, protocol = #http_protocol{} = Protocol} = Val) when Key == NetID ->
                Val#eui{protocol = Protocol#http_protocol{protocol_version = ProtocolVersion}};
            (Val) ->
                Val
        end,
        AllEUIs
    ),
    true = ets:delete_all_objects(?EUI_ETS),
    true = ets:insert(?EUI_ETS, NewEUIs),
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
    #{<<"name">> := Name, <<"net_id">> := NetID} = Entry,
    MultiBuy =
        case maps:get(<<"multi_buy">>, Entry, null) of
            null -> unlimited;
            <<"unlimited">> -> unlimited;
            Val -> Val
        end,
    Joins = maps:get(<<"joins">>, Entry, []),

    DisablePullData =
        case maps:get(<<"disable_pull_data">>, Entry, false) of
            null -> false;
            V1 -> V1
        end,

    IsActive =
        case maps:get(<<"active">>, Entry, true) of
            null -> true;
            V2 -> V2
        end,

    Protocol =
        case maps:get(<<"protocol">>, Entry, ?DEFAULT_PROTOCOL) of
            <<"udp">> ->
                try
                    Address = erlang:binary_to_list(maps:get(<<"address">>, Entry)),
                    Port = maps:get(<<"port">>, Entry),
                    {udp, Address, Port}
                catch
                    error:{badkey, BadKey} ->
                        lager:warning(
                            "could not use defauflt protocol [badkey: ~p] [net_id: ~p]",
                            [BadKey, NetID]
                        ),
                        not_configured
                end;
            <<"http">> ->
                #http_protocol{
                    endpoint = maps:get(<<"http_endpoint">>, Entry),
                    flow_type = erlang:binary_to_existing_atom(
                        maps:get(<<"http_flow_type">>, Entry, ?DEFAULT_HTTP_FLOW_TYPE)
                    ),
                    dedupe_timeout = maps:get(
                        <<"http_dedupe_timeout">>,
                        Entry,
                        ?DEFAULT_HTTP_DEDUPE_TIMEOUT
                    ),
                    auth_header = maps:get(<<"http_auth_header">>, Entry, null),
                    protocol_version =
                        case
                            maps:get(
                                <<"http_protocol_version">>,
                                Entry,
                                ?DEFAULT_HTTP_PROTOCOL_VERSION
                            )
                        of
                            <<"1.0">> -> pv_1_0;
                            <<"1.1">> -> pv_1_1
                        end
                };
            Other ->
                throw({invalid_protocol_type, Other})
        end,

    JoinRecords = lists:map(
        fun(#{<<"dev_eui">> := DevEUI, <<"app_eui">> := AppEUI}) ->
            #eui{
                name = Name,
                net_id = clean_config_value(NetID),
                protocol = Protocol,
                multi_buy = MultiBuy,
                disable_pull_data = DisablePullData,
                dev_eui = clean_config_value(DevEUI),
                app_eui = clean_config_value(AppEUI),
                buying_active = IsActive
            }
        end,
        Joins
    ),
    Routing = #devaddr{
        name = Name,
        net_id = clean_config_value(NetID),
        protocol = Protocol,
        multi_buy = MultiBuy,
        disable_pull_data = DisablePullData,
        buying_active = IsActive
    },
    [{joins, JoinRecords}, {routing, Routing}].

-spec write_config_to_ets(map()) -> ok.
write_config_to_ets(Config) ->
    #{joins := Joins, routing := Routing} = Config,
    true = ets:insert(?EUI_ETS, Joins),
    true = ets:insert(?DEVADDR_ETS, Routing),
    ok.

-spec write_config_to_disk(string()) -> ok.
write_config_to_disk(Filename) ->
    %% NOTE: Filename is fully qualified /var/data/temp_config.json
    {ok, #{joins := Joins, routing := Routing}} = pp_config:get_config(),

    CleanEUI = fun
        ('*') -> '*';
        (Num) -> pp_utils:hexstring(Num)
    end,

    MakeJoinMap = fun(#eui{app_eui = App, dev_eui = Dev}) ->
        #{app_eui => CleanEUI(App), dev_eui => CleanEUI(Dev)}
    end,

    Config = lists:map(
        fun(#devaddr{name = Name, net_id = NetID, multi_buy = MultiBuy, protocol = Protocol}) ->
            BaseMap = #{
                name => Name,
                net_id => pp_utils:hexstring(NetID),
                multi_buy => MultiBuy,
                joins => [MakeJoinMap(Join) || Join <- Joins, Join#eui.net_id == NetID]
            },
            ProtocolMap =
                case Protocol of
                    {udp, Address, Port} ->
                        #{
                            protocol => udp,
                            address => erlang:list_to_binary(Address),
                            port => Port
                        };
                    #http_protocol{
                        endpoint = Endpoint,
                        flow_type = Flow,
                        dedupe_timeout = Dedupe,
                        auth_header = Auth,
                        protocol_version = ProtocolVersion
                    } ->
                        PV =
                            case ProtocolVersion of
                                pv_1_0 -> <<"1.0">>;
                                pv_1_1 -> <<"1.1">>
                            end,
                        #{
                            protocol => http,
                            http_endpoint => Endpoint,
                            http_flow_type => Flow,
                            http_dedupe_timeout => Dedupe,
                            http_auth_header => Auth,
                            http_protocol_version => PV
                        }
                end,
            maps:merge(BaseMap, ProtocolMap)
        end,
        Routing
    ),

    Bytes = jsx:encode(Config),
    file:write_file(Filename, Bytes).

%%--------------------------------------------------------------------
%% @doc
%% Valid config values include:
%%   "*"        :: wildcard
%%   "0x123abc" :: prefixed hex number
%%   "123abc"   :: hex number
%%   1337       :: integer
%%
%% @end
%%--------------------------------------------------------------------
-spec clean_config_value(binary()) -> '*' | non_neg_integer().
clean_config_value(Num) when erlang:is_integer(Num) ->
    Num;
clean_config_value(<<"*">>) ->
    '*';
clean_config_value(<<"0x", Base16Number/binary>>) ->
    erlang:binary_to_integer(Base16Number, 16);
clean_config_value(Bin) ->
    try erlang:binary_to_integer(Bin, 16) of
        Num -> Num
    catch
        error:_ ->
            lager:warning("value is not hex: ~p", [Bin]),
            Bin
    end.
%% clean_base16(_) -> throw(malformed_base16).

%%--------------------------------------------------------------------
%% @doc
%% The storage of protocols was changed in ets.
%% Here we honor the original expectation of pp_udp_worker
%% in having the address and port broken out.
%% @end
%%--------------------------------------------------------------------
-spec maybe_clean_udp(map()) -> map().
maybe_clean_udp(#{protocol := {udp, Address, Port}} = Args) ->
    Args#{address => Address, port => Port};
maybe_clean_udp(Args) ->
    Args.

%%--------------------------------------------------------------------
%% @doc
%% UDP packets group by the gateway, we don't want to double send to the same
%% location from the same gateway. HTTP Packets group by PHash, we want to send
%% to all matches requesting.
%% @end
%%--------------------------------------------------------------------
-spec dedupe_udp_matches(list(map())) -> list(map()).
dedupe_udp_matches(Matches) ->
    {UDPMatches0, HTTPMatches} = lists:partition(
        fun(#{protocol := P}) -> element(1, P) == udp end,
        Matches
    ),
    UDPMatches1 = maps:values(
        lists:foldr(
            fun(#{protocol := P} = Entry, Acc) -> Acc#{P => Entry} end,
            #{},
            UDPMatches0
        )
    ),
    UDPMatches1 ++ HTTPMatches.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

unprefixed_hex_value_test() ->
    lists:foreach(
        fun(<<"0x", Inner/binary>> = X) ->
            ?assertEqual(clean_config_value(Inner), clean_config_value(X))
        end,
        [
            <<"0x0018b24441524632">>,
            <<"0xF03D29AC71010002">>,
            <<"0xf03d29ac71010002">>,
            <<"0x20635f000300000f">>
        ]
    ),
    ok.

join_eui_to_net_id_test() ->
    ok = pp_config:init_ets(),
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
    ?assertMatch(
        {ok, [#{protocol := {udp, _, _}}]},
        ?MODULE:lookup_eui(EUI1),
        "One EUI mapping, this one"
    ),
    ?assertMatch({error, _}, ?MODULE:lookup_eui(EUI2), "One EUI mapping, not this one"),

    ok = pp_config:load_config(BothMapped),
    ?assertMatch({ok, [#{protocol := {udp, _, _}}]}, ?MODULE:lookup_eui(EUI1), "All EUI Mapped 1"),
    ?assertMatch({ok, [#{protocol := {udp, _, _}}]}, ?MODULE:lookup_eui(EUI2), "All EUI Mapped 2"),

    ok = pp_config:load_config(WildcardMapped),
    ?assertMatch(
        {ok, [#{protocol := {udp, _, _}}]},
        ?MODULE:lookup_eui(EUI1),
        "Wildcard EUI Mapped 1"
    ),
    ?assertMatch(
        {ok, [#{protocol := {udp, _, _}}]},
        ?MODULE:lookup_eui(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = App1
            }
        ),
        "Wildcard random device EUI Mapped 1"
    ),
    ?assertMatch(
        {ok, [#{protocol := {udp, _, _}}]},
        ?MODULE:lookup_eui(EUI2),
        "Wildcard EUI Mapped 2"
    ),
    ?assertMatch(
        {ok, [#{protocol := {udp, _, _}}]},
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
