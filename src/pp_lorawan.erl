%%%-------------------------------------------------------------------
%% @doc
%% Copyright (c) 2016-2019 Petr &lt;Gotthard petr.gotthard@@centrum.cz&gt;
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%% @end
%%%-------------------------------------------------------------------
-module(pp_lorawan).

%% Functions that map Region -> Top Level Region
-export([
    index_to_datarate/2,
    datarate_to_index/2,
    parse_netid/1
]).

-type temp_datarate() :: string() | non_neg_integer().
-type temp_datarate_index() :: non_neg_integer().
-type temp_netid() :: non_neg_integer().

-spec index_to_datarate(atom(), temp_datarate_index()) -> temp_datarate().
index_to_datarate(Region, DRIndex) ->
    Plan = lora_plan:region_to_plan(Region),
    lora_plan:datarate_to_string(Plan, DRIndex).

-spec datarate_to_index(atom(), temp_datarate()) -> temp_datarate_index().
datarate_to_index(Region, DR) ->
    Plan = lora_plan:region_to_plan(Region),
    lora_plan:datarate_to_index(Plan, DR).

-spec parse_netid(number() | binary()) -> {ok, temp_netid()} | {error, invalid_netid_type}.
parse_netid(DevNum) ->
    lora_subnet:parse_netid(DevNum, big).
