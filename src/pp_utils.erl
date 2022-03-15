-module(pp_utils).

-include("packet_purchaser.hrl").

-define(ETS, pp_utils_ets).

-export([
    init_ets/0,
    get_chain/0,
    get_ledger/0,
    get_oui/0,
    pubkeybin_to_mac/1,
    animal_name/1,
    calculate_dc_amount/1,
    hex_to_binary/1,
    binary_to_hex/1,
    binary_to_hexstring/1,
    datar_to_dr/2,
    format_time/1
]).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    ok.

-spec get_chain() -> fetching | blockchain:blockchain().
get_chain() ->
    Key = blockchain_chain,
    case ets:lookup(?ETS, Key) of
        [] ->
            spawn(fun() ->
                Chain = blockchain_worker:blockchain(),
                true = ets:insert(?ETS, {Key, Chain})
            end),
            true = ets:insert(?ETS, {Key, fetching}),
            fetching;
        [{Key, fetching}] ->
            fetching;
        [{Key, Chain}] ->
            Chain
    end.

-spec get_ledger() -> blockchain_ledger_v1:ledger().
get_ledger() ->
    Key = blockchain_ledger,
    case ets:lookup(?ETS, Key) of
        [] ->
            Ledger = blockchain:ledger(),
            true = ets:insert(?ETS, {Key, Ledger}),
            Ledger;
        [{Key, Ledger}] ->
            Ledger
    end.

format_time(Time) ->
    iso8601:format(calendar:system_time_to_universal_time(Time, millisecond)).

-spec get_oui() -> undefined | non_neg_integer().
get_oui() ->
    case application:get_env(?APP, oui, undefined) of
        undefined ->
            undefined;
        %% app env comes in as a string
        OUI0 when is_list(OUI0) ->
            erlang:list_to_integer(OUI0);
        OUI0 ->
            OUI0
    end.

-spec pubkeybin_to_mac(binary()) -> binary().
pubkeybin_to_mac(PubKeyBin) ->
    <<(xxhash:hash64(PubKeyBin)):64/unsigned-integer>>.

-spec animal_name(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> {ok, string()}.
animal_name(PubKeyBin) ->
    e2qc:cache(
        animal_name_cache,
        PubKeyBin,
        fun() ->
            erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin))
        end
    ).

-spec calculate_dc_amount(non_neg_integer()) -> non_neg_integer().
calculate_dc_amount(PayloadSize) ->
    e2qc:cache(
        calculate_dc_amount_cache,
        PayloadSize,
        fun() ->
            Ledger = blockchain:ledger(),
            blockchain_utils:calculate_dc_amount(Ledger, PayloadSize)
        end
    ).

-spec binary_to_hexstring(number() | binary()) -> binary().
binary_to_hexstring(ID) when erlang:is_number(ID) ->
    binary_to_hexstring(<<ID:32/integer-unsigned>>);
binary_to_hexstring(ID) ->
    <<"0x", (binary_to_hex(ID))/binary>>.

-spec binary_to_hex(binary()) -> binary().
binary_to_hex(ID) ->
    <<<<Y>> || <<X:4>> <= ID, Y <- integer_to_list(X, 16)>>.

-spec hex_to_binary(binary()) -> binary().
hex_to_binary(ID) ->
    <<<<Z>> || <<X:8, Y:8>> <= ID, Z <- [erlang:binary_to_integer(<<X, Y>>, 16)]>>.

%%--------------------------------------------------------------------
%% lora mac region
%%--------------------------------------------------------------------

datar_to_dr(Region, DataRate) ->
    TopLevelRegion = top_level_region(Region),
    datar_to_dr_(TopLevelRegion, DataRate).

datar_to_dr_(Region, DataRate) ->
    {DR, _, _} = lists:keyfind(datar_to_tuple(DataRate), 2, datars(Region)),
    DR.

datar_to_tuple(DataRate) when is_binary(DataRate) ->
    [SF, BW] = binary:split(DataRate, [<<"SF">>, <<"BW">>], [global, trim_all]),
    {binary_to_integer(SF), binary_to_integer(BW)};
datar_to_tuple(DataRate) when is_list(DataRate) ->
    datar_to_tuple(erlang:list_to_binary(DataRate));
datar_to_tuple(DataRate) when is_integer(DataRate) ->
    %% FSK
    DataRate.

top_level_region('AS923_1') -> 'AS923';
top_level_region('AS923_2') -> 'AS923';
top_level_region('AS923_3') -> 'AS923';
top_level_region('AS923_4') -> 'AS923';
top_level_region(Region) -> Region.

datars(Region) ->
    TopLevelRegion = top_level_region(Region),
    datars_(TopLevelRegion).

datars_(Region) when Region == 'US915' ->
    [
        {0, {10, 125}, up},
        {1, {9, 125}, up},
        {2, {8, 125}, up},
        {3, {7, 125}, up},
        {4, {8, 500}, up}
        | us_down_datars()
    ];
datars_(Region) when Region == 'AU915' ->
    [
        {0, {12, 125}, up},
        {1, {11, 125}, up},
        {2, {10, 125}, up},
        {3, {9, 125}, up},
        {4, {8, 125}, up},
        {5, {7, 125}, up},
        {6, {8, 500}, up}
        | us_down_datars()
    ];
datars_(Region) when Region == 'CN470' ->
    [
        {0, {12, 125}, updown},
        {1, {11, 125}, updown},
        {2, {10, 125}, updown},
        {3, {9, 125}, updown},
        {4, {8, 125}, updown},
        {5, {7, 125}, updown}
    ];
datars_(Region) when Region == 'AS923' ->
    [
        {0, {12, 125}, updown},
        {1, {11, 125}, updown},
        {2, {10, 125}, updown},
        {3, {9, 125}, updown},
        {4, {8, 125}, updown},
        {5, {7, 125}, updown},
        {6, {7, 250}, updown},
        %% FSK
        {7, 50000, updown}
    ];
datars_(_Region) ->
    [
        {0, {12, 125}, updown},
        {1, {11, 125}, updown},
        {2, {10, 125}, updown},
        {3, {9, 125}, updown},
        {4, {8, 125}, updown},
        {5, {7, 125}, updown},
        {6, {7, 250}, updown},
        %% FSK
        {7, 50000, updown}
    ].

us_down_datars() ->
    [
        {8, {12, 500}, down},
        {9, {11, 500}, down},
        {10, {10, 500}, down},
        {11, {9, 500}, down},
        {12, {8, 500}, down},
        {13, {7, 500}, down}
    ].
