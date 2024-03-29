-module(pp_config_v2).

-include("config.hrl").

-export([parse_config/1]).

-export([hex_to_num/1]).

-spec parse_config(list(map())) -> list(#devaddr{} | #eui{}).
parse_config(Configs) ->
    lists:flatten(
        lists:map(
            fun(#{<<"name">> := Name, <<"net_id">> := NetIDBin, <<"configs">> := Inner}) ->
                NetID = hex_to_num(NetIDBin),
                eui_from_configs(Name, NetID, Inner) ++ devaddr_from_configs(Name, NetID, Inner)
            end,
            [convert_to_v2(Config) || Config <- Configs]
        )
    ).

convert_to_v2(#{<<"configs">> := _} = Config) ->
    %% if it has configs key, it's already v2
    Config;
convert_to_v2(
    #{
        <<"name">> := Name,
        <<"net_id">> := NetID
    } = Rest
) ->
    Inner = maps:without([<<"name">>, <<"net_id">>], Rest),
    #{
        <<"name">> => Name,
        <<"net_id">> => NetID,
        %% old config won't have devaddrs key
        %% and might not have joins key
        <<"configs">> => [
            maps:merge(
                #{
                    <<"devaddrs">> => [],
                    <<"joins">> => []
                },
                Inner
            )
        ]
    }.

-spec eui_from_configs(binary(), integer(), list(map())) -> list(#eui{}).
eui_from_configs(Name, NetID, Configs) ->
    lists:flatten(
        lists:map(
            fun(Entry) ->
                #{<<"joins">> := EUIs} = Entry,
                BuyingActive = get_buying_active(Entry),
                MultiBuy = get_multi_buy(Entry),
                Protocol = get_protocol(NetID, Entry),
                lists:map(
                    fun(#{<<"dev_eui">> := DevBin, <<"app_eui">> := AppBin}) ->
                        #eui{
                            name = Name,
                            net_id = NetID,
                            app_eui = hex_to_num(AppBin),
                            dev_eui = hex_to_num(DevBin),
                            multi_buy = MultiBuy,
                            protocol = Protocol,
                            console_active = BuyingActive,
                            buying_active = BuyingActive
                        }
                    end,
                    EUIs
                )
            end,
            Configs
        )
    ).

-spec get_buying_active(map()) -> boolean().
get_buying_active(#{<<"active">> := Active}) -> Active;
get_buying_active(_) -> ?DEFAULT_ACTIVE.

-spec get_multi_buy(map()) -> unlimited | non_neg_integer().
get_multi_buy(#{<<"multi_buy">> := null}) -> ?DEFAULT_MULTI_BUY;
get_multi_buy(#{<<"multi_buy">> := <<"unlimited">>}) -> unlimited;
get_multi_buy(#{<<"multi_buy">> := MB}) -> MB;
get_multi_buy(_) -> ?DEFAULT_MULTI_BUY.

-spec devaddr_from_configs(binary(), integer(), list(map())) -> list(#devaddr{}).
devaddr_from_configs(Name, NetID, Configs) ->
    lists:flatten(
        lists:map(
            fun(Entry) ->
                #{<<"devaddrs">> := DevAddrs} = Entry,
                BuyingActive = maps:get(<<"active">>, Entry, ?DEFAULT_ACTIVE),
                MultiBuy = get_multi_buy(Entry),
                Protocol = get_protocol(NetID, Entry),
                lists:map(
                    fun(#{<<"lower">> := Lower, <<"upper">> := Upper}) ->
                        #devaddr{
                            name = Name,
                            net_id = NetID,
                            protocol = Protocol,
                            multi_buy = MultiBuy,
                            console_active = BuyingActive,
                            buying_active = BuyingActive,
                            addr = {range, hex_to_num(Lower), hex_to_num(Upper)}
                        }
                    end,
                    case DevAddrs of
                        [] -> [#{<<"lower">> => <<"0x00000000">>, <<"upper">> => <<"0xFFFFFFFF">>}];
                        _ -> DevAddrs
                    end
                )
            end,
            Configs
        )
    ).

get_protocol(NetID, #{
    <<"protocol_version">> := PV,
    <<"http_auth_header">> := AuthHeader,
    <<"http_dedupe_timeout">> := DedupeTimeout,
    <<"http_endpoint">> := Endpoint,
    <<"http_flow_type">> := FT
}) ->
    Forces = application:get_env(packet_purchaser, force_net_id_protocol_version, #{}),
    ProtocolVersion =
        case maps:get(NetID, Forces, undefined) of
            undefined ->
                case PV of
                    <<"1.0">> -> pv_1_0;
                    <<"1.1">> -> pv_1_1
                end;
            V ->
                V
        end,

    #http_protocol{
        protocol_version = ProtocolVersion,
        auth_header = AuthHeader,
        dedupe_timeout = DedupeTimeout,
        endpoint = Endpoint,
        flow_type =
            case FT of
                <<"async">> -> async;
                <<"sync">> -> sync
            end
    };
get_protocol(NetID, #{<<"http_endpoint">> := Endpoint} = Entry) ->
    Forces = application:get_env(packet_purchaser, force_net_id_protocol_version, #{}),
    ProtocolVersion =
        case maps:get(NetID, Forces, undefined) of
            undefined -> maps:get(<<"http_protocol_version">>, Entry, ?DEFAULT_PROTOCOL_VERSION);
            V -> V
        end,
    #http_protocol{
        protocol_version = ProtocolVersion,
        auth_header = maps:get(<<"http_auth_header">>, Entry, null),
        dedupe_timeout = maps:get(<<"http_dedupe_timeout">>, Entry, ?DEFAULT_DEDUPE_TIMEOUT),
        endpoint = Endpoint,
        flow_type =
            case maps:get(<<"http_flow_type">>, Entry, ?DEFAULT_FLOW_TYPE) of
                <<"async">> -> async;
                <<"sync">> -> sync
            end
    };
get_protocol(_NetID, #{<<"address">> := UDPAddress, <<"port">> := UDPPort}) ->
    #udp{address = erlang:binary_to_list(UDPAddress), port = UDPPort};
get_protocol(_NetID, #{}) ->
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

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

upgrade_config_test() ->
    Config = #{
        <<"name">> => <<"test">>,
        <<"net_id">> => 1234,
        <<"protocol">> => <<"http">>,
        <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
        <<"http_flow_type">> => <<"async">>,
        <<"joins">> => [
            #{<<"dev_eui">> => 1234, <<"app_eui">> => 7890}
        ]
    },
    ?assertEqual(
        #{
            <<"name">> => <<"test">>,
            <<"net_id">> => 1234,
            <<"configs">> => [
                #{
                    <<"protocol">> => <<"http">>,
                    <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
                    <<"http_flow_type">> => <<"async">>,
                    <<"joins">> => [
                        #{<<"dev_eui">> => 1234, <<"app_eui">> => 7890}
                    ],
                    <<"devaddrs">> => []
                }
            ]
        },
        convert_to_v2(Config)
    ),
    ok.

unprefixed_hex_value_test() ->
    lists:foreach(
        fun(<<"0x", Inner/binary>> = X) ->
            ?assertEqual(hex_to_num(Inner), hex_to_num(X))
        end,
        [
            <<"0x0018b24441524632">>,
            <<"0xF03D29AC71010002">>,
            <<"0xf03d29ac71010002">>,
            <<"0x20635f000300000f">>
        ]
    ),
    ok.

-endif.
