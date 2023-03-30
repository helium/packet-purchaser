-module(pp_utils).

-include("packet_purchaser.hrl").

-define(ETS, pp_utils_ets).

-define(LOCATION_NONE, no_location).
-define(HOTSPOT_LOCATION_CACHE, hotspot_location_cache).

-type location() :: ?LOCATION_NONE | {Index :: pos_integer(), Lat :: float(), Long :: float()}.
-export_type([location/0]).

-export([
    is_chain_dead/0,
    chain/0,
    ledger/0,
    calculate_dc_amount/1,
    get_hotspot_location/1
]).

-export([
    load_key/1,
    pubkeybin/0,
    pubkey_b58/0
]).

-export([
    init_ets/0,
    init_location_cache/0,
    get_oui/0,
    pubkeybin_to_mac/1,
    animal_name/1,
    hex_to_binary/1,
    hexstring_to_binary/1,
    binary_to_hex/1,
    binary_to_hexstring/1,
    hexstring/1, hexstring/2,
    hexstring_to_int/1,
    format_time/1,
    get_env_int/2,
    get_env_bool/2,
    uint32/1,
    random_non_miner_predicate/1
]).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    ok.

-spec init_location_cache() -> ok.
init_location_cache() ->
    {ok, HLC} = cream:new(200_00, [{initial_capacity, 20_000}, {seconds_to_live, 600}]),
    ok = persistent_term:put(?HOTSPOT_LOCATION_CACHE, HLC),
    ok.

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

-spec hexstring(number()) -> binary().
hexstring(Bin) when erlang:is_binary(Bin) ->
    binary_to_hexstring(Bin);
hexstring(Num) when erlang:is_number(Num) ->
    Inter0 = erlang:integer_to_binary(Num, 16),
    Inter1 = string:pad(Inter0, 6, leading, $0),
    Inter = erlang:iolist_to_binary(Inter1),
    <<"0x", Inter/binary>>;
hexstring(Other) ->
    throw({unknown_hexstring_conversion, Other}).

-spec hexstring(non_neg_integer(), non_neg_integer()) -> binary().
hexstring(Bin, Length) when erlang:is_binary(Bin) ->
    Inter0 = binary_to_hex(Bin),
    Inter1 = string:pad(Inter0, Length, leading, $0),
    Inter = erlang:iolist_to_binary(Inter1),
    <<"0x", Inter/binary>>;
hexstring(Num, Length) ->
    Inter0 = erlang:integer_to_binary(Num, 16),
    Inter1 = string:pad(Inter0, Length, leading, $0),
    Inter = erlang:iolist_to_binary(Inter1),
    <<"0x", Inter/binary>>.

-spec hexstring_to_int(binary()) -> integer().
hexstring_to_int(<<"0x", Num/binary>>) ->
    erlang:binary_to_integer(Num, 16);
hexstring_to_int(Bin) ->
    erlang:binary_to_integer(Bin, 16).

-spec binary_to_hexstring(number() | binary()) -> binary().
binary_to_hexstring(ID) when erlang:is_number(ID) ->
    binary_to_hexstring(<<ID:32/integer-unsigned>>);
binary_to_hexstring(ID) ->
    <<"0x", (binary_to_hex(ID))/binary>>.

-spec hexstring_to_binary(binary()) -> binary().
hexstring_to_binary(<<"0x", Bin/binary>>) ->
    hex_to_binary(Bin);
hexstring_to_binary(Bin) when erlang:is_binary(Bin) ->
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

-spec get_env_bool(atom(), boolean()) -> boolean().
get_env_bool(Key, Default) ->
    case application:get_env(packet_purchaser, Key, Default) of
        "true" -> true;
        true -> true;
        _ -> false
    end.

-spec get_hotspot_location(PubKeyBin :: binary()) ->
    ?LOCATION_NONE
    | {Index :: pos_integer(), Lat :: float(), Long :: float()}.
get_hotspot_location(PubKeyBin) ->
    case ?MODULE:is_chain_dead() orelse pp_utils:get_env_bool(enable_ics_location, false) of
        true ->
            pp_ics_gateway_location_worker:get(PubKeyBin);
        false ->
            case persistent_term:get(?HOTSPOT_LOCATION_CACHE, undefined) of
                undefined ->
                    chain_get_hotspot_location(PubKeyBin);
                Cache ->
                    cream:cache(Cache, PubKeyBin, fun() -> chain_get_hotspot_location(PubKeyBin) end)
            end
    end.


-spec uint32(number()) -> 0..4294967295.
uint32(Num) ->
    Num band 16#FFFF_FFFF.

random_non_miner_predicate(Peer) ->
    not libp2p_peer:is_stale(Peer, timer:minutes(360)) andalso
        maps:get(<<"node_type">>, libp2p_peer:signed_metadata(Peer), undefined) /= <<"gateway">>.

%% ===================================================================
%% ===================================================================

-spec is_chain_dead() -> boolean().
is_chain_dead() ->
    pp_utils:get_env_bool(is_chain_dead, false).

-spec chain() -> blockchain:blockchain().
chain() ->
    Key = pp_blockchain,
    case persistent_term:get(Key, undefined) of
        undefined ->
            Chain = blockchain_worker:blockchain(),
            ok = persistent_term:put(Key, Chain),
            Chain;
        Chain ->
            Chain
    end.

-spec ledger() -> blockchain_ledger_v1:ledger().
ledger() ->
    blockchain:ledger(?MODULE:chain()).

-spec calculate_dc_amount(PayloadSize :: non_neg_integer()) -> pos_integer() | {error, any()}.
calculate_dc_amount(PayloadSize) ->
    case ?MODULE:is_chain_dead() of
        false -> blockchain_utils:calculate_dc_amount(?MODULE:ledger(), PayloadSize);
        %% 1 DC per 24 bytes of data
        true -> erlang:ceil(PayloadSize / 24)
    end.

-spec load_key(string()) ->
    {libp2p_crypto:pubkey(), libp2p_crypto:sig_fun(), libp2p_crypto:ecdh_fun()}.
load_key(BaseDir) ->
    SwarmKey = filename:join([BaseDir, "blockchain", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    {Pubkey, _, _} =
        Key =
        case libp2p_crypto:load_keys(SwarmKey) of
            {ok, #{secret := PrivKey, public := PubKey}} ->
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)};
            {error, enoent} ->
                KeyMap =
                    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(
                        ecc_compact
                    ),
                ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)}
        end,
    ok = persistent_term:put(pp_pubkeybin, libp2p_crypto:pubkey_to_bin(Pubkey)),
    Key.

-spec pubkeybin() -> binary().
pubkeybin() ->
    Key = pp_pubkeybin,
    case persistent_term:get(Key, undefined) of
        undefined ->
            throw(pubkey_should_be_in_persistent_term);
        PubKeyBin ->
            PubKeyBin
    end.

-spec pubkey_b58() -> string().
pubkey_b58() ->
    libp2p_crypto:bin_to_b58(pubkeybin()).

%% ===================================================================
%% Internal Functions
%% ===================================================================

-spec chain_get_hotspot_location(PubKeyBin :: binary()) ->
    ?LOCATION_NONE
    | {Index :: pos_integer(), Lat :: float(), Long :: float()}.
chain_get_hotspot_location(PubKeyBin) ->
    Ledger = ?MODULE:ledger(),
    case blockchain_ledger_v1:find_gateway_info(PubKeyBin, Ledger) of
        {error, _} ->
            ?LOCATION_NONE;
        {ok, Hotspot} ->
            case blockchain_ledger_gateway_v2:location(Hotspot) of
                undefined ->
                    ?LOCATION_NONE;
                Index ->
                    {Lat, Long} = h3:to_geo(Index),
                    {Index, Lat, Long}
            end
    end.
