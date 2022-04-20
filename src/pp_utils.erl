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
    hexstring_to_binary/1,
    binary_to_hex/1,
    binary_to_hexstring/1,
    format_time/1,
    get_env_int/2
]).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    _ = ?MODULE:get_chain(),
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

-spec get_ledger() -> fetching | blockchain_ledger_v1:ledger().
get_ledger() ->
    case get_chain() of
        fetching -> fetching;
        Chain -> blockchain:ledger(Chain)
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

-spec hexstring_to_binary(binary()) -> binary().
hexstring_to_binary(<<"0x", Bin/binary>>) ->
    hex_to_binary(Bin);
hexstring_to_binary(_Invalid) ->
    throw({invalid_hexstring_binary, _Invalid}).

-spec binary_to_hex(binary()) -> binary().
binary_to_hex(ID) ->
    <<<<Y>> || <<X:4>> <= ID, Y <- integer_to_list(X, 16)>>.

-spec hex_to_binary(binary()) -> binary().
hex_to_binary(ID) ->
    <<<<Z>> || <<X:8, Y:8>> <= ID, Z <- [erlang:binary_to_integer(<<X, Y>>, 16)]>>.

-spec get_env_int(atom(), integer()) -> integer().
get_env_int(Key, Default) ->
    case application:get_env(packet_purchaser, Key, Default) of
        [] -> Default;
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        I -> I
    end.
