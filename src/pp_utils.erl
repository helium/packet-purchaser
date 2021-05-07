-module(pp_utils).

-include("packet_purchaser.hrl").

-export([
    get_oui/1,
    pubkeybin_to_mac/1,
    accept_joins/0,
    allowed_net_ids/0
]).

-spec get_oui(Chain :: blockchain:blockchain()) -> non_neg_integer() | undefined.
get_oui(Chain) ->
    Ledger = blockchain:ledger(Chain),
    PubkeyBin = blockchain_swarm:pubkey_bin(),
    case blockchain_ledger_v1:get_oui_counter(Ledger) of
        {error, _} ->
            undefined;
        {ok, 0} ->
            undefined;
        {ok, _OUICounter} ->
            %% there are some ouis on chain
            find_oui(PubkeyBin, Ledger)
    end.

-spec pubkeybin_to_mac(binary()) -> binary().
pubkeybin_to_mac(PubKeyBin) ->
    <<(xxhash:hash64(PubKeyBin)):64/unsigned-integer>>.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_oui(
    PubkeyBin :: libp2p_crypto:pubkey_bin(),
    Ledger :: blockchain_ledger_v1:ledger()
) -> non_neg_integer() | undefined.
find_oui(PubkeyBin, Ledger) ->
    MyOUIs = blockchain_ledger_v1:find_router_ouis(PubkeyBin, Ledger),
    case application:get_env(?APP, oui, undefined) of
        undefined ->
            %% still check on chain
            case MyOUIs of
                [] -> undefined;
                [OUI] -> OUI;
                [H | _T] -> H
            end;
        OUI0 when is_list(OUI0) ->
            %% app env comes in as a string
            OUI = list_to_integer(OUI0),
            check_oui_on_chain(OUI, MyOUIs);
        OUI ->
            check_oui_on_chain(OUI, MyOUIs)
    end.

-spec check_oui_on_chain(non_neg_integer(), [non_neg_integer()]) -> non_neg_integer() | undefined.
check_oui_on_chain(OUI, OUIsOnChain) ->
    case lists:member(OUI, OUIsOnChain) of
        false ->
            undefined;
        true ->
            OUI
    end.

-spec accept_joins() -> boolean().
accept_joins() ->
    case application:get_env(packet_purchaser, accept_joins, true) of
        "false" -> false;
        false -> false;
        _ -> true
    end.

-spec allowed_net_ids() -> list(integer()).
allowed_net_ids() ->
    case application:get_env(packet_purchaser, net_ids, []) of
        [] -> allow_all;
        [allow_all] ->
            allow_all;
        %% What you put in the list is what you get out.
        %% Ex: [16#000001, 16#000002]
        [ID | _] = IDS when erlang:is_number(ID) ->
            IDS;
        %% Comma separated string, will be turned into base-16 integers.
        %% ex: "000001, 0000002"
        IDS when erlang:is_list(IDS) ->
            Nums = string:split(IDS, ",", all),
            lists:map(fun(Num) -> erlang:list_to_integer(string:trim(Num), 16) end, Nums)
    end.
