-module(lorawan_devaddr).

-export([net_id/1]).

-spec net_id(binary()) -> {ok, non_neg_integer()} | {error, invalid_net_id_type}.
net_id(DevNum) when erlang:is_number(DevNum) ->
    net_id(<<DevNum:32/integer-unsigned>>);
net_id(DevAddr) ->
    try
        Type = net_id_type(DevAddr),
        NetID =
            case Type of
                0 -> get_net_id(DevAddr, 1, 6);
                1 -> get_net_id(DevAddr, 2, 6);
                2 -> get_net_id(DevAddr, 3, 9);
                3 -> get_net_id(DevAddr, 4, 11);
                4 -> get_net_id(DevAddr, 5, 12);
                5 -> get_net_id(DevAddr, 6, 13);
                6 -> get_net_id(DevAddr, 7, 15);
                7 -> get_net_id(DevAddr, 8, 17)
            end,
        {ok, NetID bor (Type bsl 21)}
    catch
        throw:invalid_net_id_type:_ ->
            {error, invalid_net_id_type}
    end.

-spec net_id_type(binary()) -> 0..7.
net_id_type(<<First:8/integer-unsigned, _/binary>>) ->
    net_id_type(First, 7).

-spec net_id_type(non_neg_integer(), non_neg_integer()) -> 0..7.
net_id_type(_, -1) ->
    throw(invalid_net_id_type);
net_id_type(Prefix, Index) ->
    case Prefix band (1 bsl Index) of
        0 -> 7 - Index;
        _ -> net_id_type(Prefix, Index - 1)
    end.

-spec get_net_id(binary(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
get_net_id(DevAddr, PrefixLength, NwkIDBits) ->
    <<Temp:32/integer-unsigned>> = DevAddr,
    %% Remove type prefix
    One = uint32(Temp bsl PrefixLength),
    %% Remove NwkAddr suffix
    Two = uint32(One bsr (32 - NwkIDBits)),

    IgnoreSize = 32 - NwkIDBits,
    <<_:IgnoreSize, NetID:NwkIDBits/integer-unsigned>> = <<Two:32/integer-unsigned>>,
    NetID.

-spec uint32(integer()) -> integer().
uint32(Num) ->
    Num band 4294967295.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

net_id_test() ->
    %% CP data
    ?assertEqual({ok, 16#00002D}, net_id(<<91, 255, 255, 255>>), "[45] == 2D == 45 type 0"),
    ?assertEqual({ok, 16#20002D}, net_id(<<173, 255, 255, 255>>), "[45] == 2D == 45 type 1"),
    ?assertEqual({ok, 16#40016D}, net_id(<<214, 223, 255, 255>>), "[1,109] == 16D == 365 type 2"),
    ?assertEqual({ok, 16#6005B7}, net_id(<<235, 111, 255, 255>>), "[5,183] == 5B7 == 1463 type 3"),
    ?assertEqual(
        {ok, 16#800B6D},
        net_id(<<245, 182, 255, 255>>),
        "[11, 109] == B6D == 2925 type 4"
    ),
    ?assertEqual(
        {ok, 16#A016DB},
        net_id(<<250, 219, 127, 255>>),
        "[22,219] == 16DB == 5851 type 5"
    ),
    ?assertEqual(
        {ok, 16#C05B6D},
        net_id(<<253, 109, 183, 255>>),
        "[91, 109] == 5B6D == 23405 type 6"
    ),
    ?assertEqual(
        {ok, 16#E16DB6},
        net_id(<<254, 182, 219, 127>>),
        "[1,109,182] == 16DB6 == 93622 type 7"
    ),
    ?assertEqual(
        {error, invalid_net_id_type},
        net_id(<<255, 255, 255, 255>>),
        "Invalid DevAddr"
    ),

    % Actility spreadsheet examples
    ?assertEqual({ok, 0}, net_id(<<0:1, 0:1, 0:1, 0:1, 0:1, 0:1, 0:1, 0:25>>)),
    ?assertEqual({ok, 1}, net_id(<<0:1, 0:1, 0:1, 0:1, 0:1, 0:1, 1:1, 0:25>>)),
    ?assertEqual({ok, 2}, net_id(<<0:1, 0:1, 0:1, 0:1, 0:1, 1:1, 0:1, 0:25>>)),

    %% Mis-parsed as netid 4 of type 3
    ?assertEqual({ok, 16#600004}, net_id(<<224, 9, 171, 205>>), "hex_to_binary(<<'E009ABCD'>>)"),
    %% Valid DevAddr, NetID not assigned
    ?assertEqual({ok, 16#20002D}, net_id(<<173, 255, 255, 255>>), "hex_to_binary(<<'ADFFFFFF'>>)"),
    %% Less than 32 bit number
    ?assertEqual({ok, 0}, net_id(46377)),

    % Louis test data
    ?assertEqual({ok, 16#600002}, net_id(<<224, 4, 0, 1>>)),
    ?assertEqual({ok, 16#600002}, net_id(<<224, 5, 39, 132>>)),
    ?assertEqual({ok, 16#000002}, net_id(<<4, 16, 190, 163>>)).

-endif.
