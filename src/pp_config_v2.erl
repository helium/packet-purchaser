-module(pp_config_v2).

-export([parse_config/1]).

-export([hex_to_num/1]).

-type protocol_version() :: pv_1_0 | pv_1_1.

-record(http_protocol, {
    endpoint :: binary(),
    flow_type :: async | sync,
    dedupe_timeout :: non_neg_integer(),
    auth_header :: null | binary(),
    protocol_version :: protocol_version()
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
    protocol :: protocol()
}).

-spec parse_config(list(map())) -> list(#devaddr{} | #eui{}).
parse_config(Configs) ->
    lists:flatten(
        lists:map(
            fun(#{<<"name">> := Name, <<"net_id">> := NetIDBin, <<"configs">> := Inner}) ->
                NetID = hex_to_num(NetIDBin),
                eui_from_configs(Name, NetID, Inner) ++ devaddr_from_configs(Name, NetID, Inner)
            end,
            Configs
        )
    ).

-spec eui_from_configs(binary(), integer(), list(map())) -> list(#eui{}).
eui_from_configs(Name, NetID, Configs) ->
    lists:flatten(
        lists:map(
            fun(Entry) ->
                #{
                    <<"active">> := BuyingActive,
                    <<"joins">> := EUIs,
                    <<"multi_buy">> := MultiBuy
                } =
                    Entry,
                Protocol = protocol_from_config(Entry),
                lists:map(
                    fun(#{<<"dev_eui">> := DevBin, <<"app_eui">> := AppBin}) ->
                        #eui{
                            name = Name,
                            net_id = NetID,
                            app_eui = hex_to_num(AppBin),
                            dev_eui = hex_to_num(DevBin),
                            multi_buy = hex_to_num(MultiBuy),
                            protocol = Protocol,
                            buying_active = BuyingActive
                        }
                    end,
                    EUIs
                )
            end,
            Configs
        )
    ).

-spec devaddr_from_configs(binary(), integer(), list(map())) -> list(#devaddr{}).
devaddr_from_configs(Name, NetID, Configs) ->
    lists:flatten(
        lists:map(
            fun(Entry) ->
                #{
                    <<"active">> := BuyingActive,
                    <<"devaddrs">> := DevAddrs,
                    <<"multi_buy">> := MultiBuy
                } =
                    Entry,
                Protocol = protocol_from_config(Entry),
                lists:map(
                    fun(#{<<"lower">> := Lower, <<"upper">> := Upper}) ->
                        D =
                            case {Lower, Upper} of
                                {Same, Same} -> {single, hex_to_num(Same)};
                                _ -> {range, hex_to_num(Lower), hex_to_num(Upper)}
                            end,
                        #devaddr{
                            name = Name,
                            net_id = NetID,
                            protocol = Protocol,
                            multi_buy = hex_to_num(MultiBuy),
                            buying_active = BuyingActive,
                            addr = D
                        }
                    end,
                    DevAddrs
                )
            end,
            Configs
        )
    ).

protocol_from_config(#{
    <<"protocol_version">> := PV,
    <<"http_auth_header">> := AuthHeader,
    <<"http_dedupe_timeout">> := DedupeTimeout,
    <<"http_endpoint">> := Endpoint,
    <<"http_flow_type">> := FT
}) ->
    #http_protocol{
        protocol_version =
            case PV of
                <<"1.0">> -> pv_1_0;
                <<"1.1">> -> pv_1_1
            end,
        auth_header = AuthHeader,
        dedupe_timeout = DedupeTimeout,
        endpoint = Endpoint,
        flow_type =
            case FT of
                <<"async">> -> async;
                <<"sync">> -> sync
            end
    };
protocol_from_config(#{}) ->
    not_configured.

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
-spec hex_to_num(binary()) -> '*' | non_neg_integer().
hex_to_num(Num) when erlang:is_integer(Num) ->
    Num;
hex_to_num(<<"*">>) ->
    '*';
hex_to_num(<<"0x", Base16Number/binary>>) ->
    erlang:binary_to_integer(Base16Number, 16);
hex_to_num(Bin) ->
    try erlang:binary_to_integer(Bin, 16) of
        Num -> Num
    catch
        error:_ ->
            lager:warning("value is not hex: ~p", [Bin]),
            Bin
    end.
