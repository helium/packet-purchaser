-module(pp_lorawan).

-export([
    datarate_to_index/2,
    index_to_datarate/2,
    parse_netid/1
]).

%% Types =============================================================

%%           <<"SFxxBWxxx">> | FSK
-type datarate() :: string() | non_neg_integer().
-type datarate_index() :: non_neg_integer().
-type netid() :: non_neg_integer().

%% Functions =========================================================

-spec datarate_to_index(atom(), datarate()) -> datarate_index().
datarate_to_index(Region, DataRate0) ->
    Plan = lora_plan:region_to_plan(Region),
    %% lora_plan accepts binaries and numbers.
    DataRate1 =
        case erlang:is_list(DataRate0) of
            true -> erlang:list_to_binary(DataRate0);
            false -> DataRate0
        end,
    lora_plan:datarate_to_index(Plan, DataRate1).

-spec index_to_datarate(atom(), datarate_index()) -> datarate().
index_to_datarate(Region, DRIndex) ->
    Plan = lora_plan:region_to_plan(Region),
    DR = lora_plan:datarate_to_binary(Plan, DRIndex),
    erlang:binary_to_list(DR).

-spec parse_netid(number() | binary()) -> {ok, netid()} | {error, invalid_netid_type}.
parse_netid(DevNum) ->
    lora_subnet:parse_netid(DevNum).
