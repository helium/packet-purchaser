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
    parse_netid/1,

    datar_to_dr/2,
    dr_to_datar/2
]).

-type temp_datarate() :: string() | non_neg_integer().
-type temp_datarate_index() :: non_neg_integer().
-type temp_netid() :: non_neg_integer().

-spec index_to_datarate(atom(), temp_datarate_index()) -> temp_datarate().
index_to_datarate(Region, DRIndex) ->
    erlang:binary_to_list(dr_to_datar(Region, DRIndex)).

-spec datarate_to_index(atom(), temp_datarate()) -> temp_datarate_index().
datarate_to_index(Region, DR) ->
    datar_to_dr(Region, DR).

-spec parse_netid(number() | binary()) -> {ok, temp_netid()} | {error, invalid_netid_type}.
parse_netid(DevNum) ->
    lora_subnet:parse_netid(DevNum, big).

%% ------------------------------------------------------------------
%% @doc === Types and Terms ===
%%
%% dr        -> Datarate Index
%% datar     -> ```<<"SFxxBWxx">>'''
%% datarate  -> Datarate Tuple {spreading, bandwidth}
%%
%% Frequency -> A Frequency
%%              - whole number 4097 (representing 409.7)
%%              - float 409.7
%% Channel   -> Index of a frequency in a regions range
%% Region    -> Atom representing a region
%%
%% @end
%% ------------------------------------------------------------------

%%        <<"SFxxBWxxx">> | FSK
-type datar() :: string() | binary() | non_neg_integer().
-type dr() :: non_neg_integer().
-type datarate() :: {Spreading :: non_neg_integer(), Bandwidth :: non_neg_integer()}.

%% ------------------------------------------------------------------
%% Region Wrapped Helper Functions
%% ------------------------------------------------------------------

-spec datar_to_dr(atom(), datar()) -> dr().
datar_to_dr(Region, DataRate) ->
    TopLevelRegion = top_level_region(Region),
    datar_to_dr_(TopLevelRegion, DataRate).

-spec dr_to_datar(atom(), dr()) -> datar().
dr_to_datar(Region, DR) ->
    TopLevelRegion = top_level_region(Region),
    dr_to_datar_(TopLevelRegion, DR).

-spec datars(atom()) -> list({dr(), datarate(), up | down | updown}).
datars(Region) ->
    TopLevelRegion = top_level_region(Region),
    datars_(TopLevelRegion).

%% ------------------------------------------------------------------
%% @doc Top Level Region
%% AS923 has sub-regions. Besides for the cflist during joining,
%% they should be treated the same.
%% @end
%% ------------------------------------------------------------------
-spec top_level_region(atom()) -> atom().
top_level_region('AS923_1') -> 'AS923';
top_level_region('AS923_2') -> 'AS923';
top_level_region('AS923_3') -> 'AS923';
top_level_region('AS923_4') -> 'AS923';
top_level_region(Region) -> Region.

%% data rate and end-device output power encoding
-spec datars_(atom()) -> list({dr(), datarate(), up | down | updown}).
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

-spec us_down_datars() -> list({dr(), datarate(), down}).
us_down_datars() ->
    [
        {8, {12, 500}, down},
        {9, {11, 500}, down},
        {10, {10, 500}, down},
        {11, {9, 500}, down},
        {12, {8, 500}, down},
        {13, {7, 500}, down}
    ].

%% ------------------------------------------------------------------
%% @doc Datarate Index to Datarate Tuple
%% @end
%% ------------------------------------------------------------------
-spec dr_to_tuple(atom(), dr()) -> datarate().
dr_to_tuple(Region, DR) ->
    {_, DataRate, _} = lists:keyfind(DR, 1, datars(Region)),
    DataRate.

%% ------------------------------------------------------------------
%% @doc Datarate Index to Datarate Binary
%% @end
%% ------------------------------------------------------------------
-spec dr_to_datar_(atom(), dr()) -> datar().
dr_to_datar_(Region, DR) ->
    tuple_to_datar(dr_to_tuple(Region, DR)).

%% ------------------------------------------------------------------
%% @doc Datarate Tuple to Datarate Index
%% @end
%% ------------------------------------------------------------------
-spec datar_to_dr_(atom(), datar()) -> dr().
datar_to_dr_(Region, DataRate) ->
    {DR, _, _} = lists:keyfind(datar_to_tuple(DataRate), 2, datars(Region)),
    DR.

%% ------------------------------------------------------------------
%% @doc Datarate Tuple to Datarate Binary
%% NOTE: FSK is a special case.
%% @end
%% ------------------------------------------------------------------
-spec tuple_to_datar(datarate()) -> datar().
tuple_to_datar({SF, BW}) ->
    <<"SF", (integer_to_binary(SF))/binary, "BW", (integer_to_binary(BW))/binary>>.

%% ------------------------------------------------------------------
%% @doc Datarate Binary to Datarate Tuple
%% NOTE: FSK is a special case.
%% @end
%% ------------------------------------------------------------------
-spec datar_to_tuple(datar()) -> datarate() | non_neg_integer().

datar_to_tuple(DataRate) when is_binary(DataRate) ->
    [SF, BW] = binary:split(DataRate, [<<"SF">>, <<"BW">>], [global, trim_all]),
    {binary_to_integer(SF), binary_to_integer(BW)};
datar_to_tuple(DataRate) when is_list(DataRate) ->
    datar_to_tuple(erlang:list_to_binary(DataRate));
datar_to_tuple(DataRate) when is_integer(DataRate) ->
    %% FSK
    DataRate.
