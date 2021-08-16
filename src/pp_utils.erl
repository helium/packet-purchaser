-module(pp_utils).

-include("packet_purchaser.hrl").

-export([
    get_oui/0,
    pubkeybin_to_mac/1,
    get_metrics_filename/0,
    get_lns_metrics_filename/0,
    hex_to_binary/1
]).

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

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec get_metrics_filename() -> string().
get_metrics_filename() ->
    application:get_env(?APP, pp_metrics_file, "/var/data/pp_metrics.dat").

-spec get_lns_metrics_filename() -> string().
get_lns_metrics_filename() ->
    application:get_env(?APP, pp_lns_metrics_file, "/var/data/pp_lns_metrics.dat").

-spec hex_to_binary(binary()) -> binary().
hex_to_binary(ID) ->
    <<<<Z>> || <<X:8, Y:8>> <= ID, Z <- [erlang:binary_to_integer(<<X, Y>>, 16)]>>.
