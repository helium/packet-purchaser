%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser State Channel Packet Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(pp_sc_packet_handler).

-include("packet_purchaser.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-export([
    handle_offer/2,
    handle_packet/3
]).

-export([
    init_ets/0,
    get_netid_packet_counts/0
]).

%% Offer rejected reasons
-define(NOT_ACCEPTING_JOINS, not_accepting_joins).
-define(NET_ID_REJECTED, net_id_rejected).
-define(NET_TYPE_PREFIX_NOT_ZERO, net_type_prefix_not_zero).

-define(ETS, pp_net_id_packet_count).

%% ------------------------------------------------------------------
%% Packet Handler Functions
%% ------------------------------------------------------------------

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok.
handle_offer(Offer, _HandlerPid) ->
    case blockchain_state_channel_offer_v1:routing(Offer) of
        #routing_information_pb{data = {eui, _EUI}} ->
            case accept_joins() of
                true -> ok;
                false -> {error, ?NOT_ACCEPTING_JOINS}
            end;
        #routing_information_pb{data = {devaddr, DevAddr}} ->
            case allowed_net_ids() of
                allow_all ->
                    ok;
                IDs ->
                    {NetID, _NetIDType} = net_id(<<DevAddr:32/integer-unsigned>>),
                    lager:debug("Offer [Devaddr: ~p] [NetID: ~p] [Type: ~p]", [
                        DevAddr,
                        NetID,
                        _NetIDType
                    ]),
                    case lists:member(NetID, IDs) of
                        true -> ok;
                        false -> {error, ?NET_ID_REJECTED}
                    end
            end
    end.

-spec handle_packet(blockchain_state_channel_packet_v1:packet(), pos_integer(), pid()) -> ok.
handle_packet(SCPacket, PacketTime, Pid) ->
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Token = semtech_udp:token(),
    MAC = pp_utils:pubkeybin_to_mac(PubKeyBin),
    Tmst = blockchain_helium_packet_v1:timestamp(Packet),
    Payload = blockchain_helium_packet_v1:payload(Packet),
    UDPData = semtech_udp:push_data(
        Token,
        MAC,
        #{
            time => iso8601:format(calendar:system_time_to_universal_time(Tmst, millisecond)),
            tmst => PacketTime band 4294967295,
            freq => blockchain_helium_packet_v1:frequency(Packet),
            rfch => 0,
            modu => <<"LORA">>,
            codr => <<"4/5">>,
            stat => 1,
            chan => 0,
            datr => erlang:list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
            rssi => erlang:trunc(blockchain_helium_packet_v1:signal_strength(Packet)),
            lsnr => blockchain_helium_packet_v1:snr(Packet),
            size => erlang:byte_size(Payload),
            data => base64:encode(Payload)
        }
    ),

    {devaddr, DevAddr} = blockchain_helium_packet_v1:routing_info(Packet),
    {NetID, _NetIDType} = net_id(<<DevAddr:32/integer-unsigned>>),
    lager:debug("Packet [Devaddr: ~p] [NetID: ~p] [Type: ~p]", [DevAddr, NetID, _NetIDType]),

    try
        case pp_udp_sup:maybe_start_worker(PubKeyBin, net_id_udp_args(NetID)) of
            {ok, WorkerPid} ->
                _ = ets:update_counter(?ETS, NetID, 1, {NetID, 0}),
                pp_udp_worker:push_data(WorkerPid, Token, UDPData, Pid);
            {error, _Reason} = Error ->
                lager:error("failed to start udp connector for ~p: ~p", [
                    blockchain_utils:addr2name(PubKeyBin),
                    _Reason
                ]),
                Error
        end
    catch
        error:{badkey, NetID} ->
            lager:debug("Ignoring unconfigured NetID ~p", [NetID])
    end.

%% ------------------------------------------------------------------
%% Counter Functions
%% ------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    ok.

-spec get_netid_packet_counts() -> map().
get_netid_packet_counts() ->
    maps:from_list(ets:tab2list(?ETS)).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec net_id(binary()) -> {non_neg_integer(), 0..7}.
net_id(DevAddr) ->
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
    {NetID, Type}.

-spec net_id_type(binary()) -> 0..7.
net_id_type(<<First:8/integer-unsigned, _/binary>>) ->
    net_id_type(First, 7).

-spec net_id_type(non_neg_integer(), non_neg_integer()) -> 0..7.
net_id_type(Prefix, Index) ->
    case Prefix band (1 bsl Index) of
        0 -> 7 - Index;
        _ -> net_id_type(Prefix, Index - 1)
    end.

-spec get_net_id(binary(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
get_net_id(DevAddr, PrefixLength, NwkIDBits) ->
    <<Temp:32/integer-unsigned>> = DevAddr,
    One = uint32(Temp bsl PrefixLength),
    Two = uint32(One bsr (32 - NwkIDBits)),

    IgnoreSize = 32 - NwkIDBits,
    <<_:IgnoreSize, NetID:NwkIDBits/integer-unsigned>> = <<Two:32/integer-unsigned>>,
    NetID.

-spec uint32(integer()) -> integer().
uint32(Num) ->
    Num band 4294967295.

-spec accept_joins() -> boolean().
accept_joins() ->
    case application:get_env(?APP, accept_joins, true) of
        "false" -> false;
        false -> false;
        _ -> true
    end.

-spec allowed_net_ids() -> list(integer()) | allow_all.
allowed_net_ids() ->
    case application:get_env(?APP, net_ids, []) of
        [] ->
            allow_all;
        [allow_all] ->
            allow_all;
        NetIdsMap when is_map(NetIdsMap) ->
            maps:keys(NetIdsMap);
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

-spec net_id_udp_args(non_neg_integer()) -> map().
net_id_udp_args(NetID) ->
    case application:get_env(?APP, net_ids, undefined) of
        Map when erlang:is_map(Map) ->
            maps:get(NetID, Map);
        _UndefinedOrList ->
            #{}
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

accept_joins_test() ->
    application:set_env(?APP, accept_joins, "false"),
    ?assertEqual(false, accept_joins(), "String false is false"),

    application:set_env(?APP, accept_joins, false),
    ?assertEqual(false, accept_joins(), "Atom false is false"),

    application:set_env(?APP, accept_joins, true),
    ?assertEqual(true, accept_joins(), "Atom true is true"),

    application:set_env(?APP, accept_joins, "1234567890"),
    ?assertEqual(true, accept_joins(), "Random data is true"),

    ok.

allowed_net_ids_test() ->
    application:set_env(?APP, net_ids, []),
    ?assertEqual(allow_all, allowed_net_ids(), "Empty list is open filter"),

    %% Case to support putting multiple net ids from .env file
    application:set_env(?APP, net_ids, [allow_all]),
    ?assertEqual(allow_all, allowed_net_ids(), "allow_all atom in list allows all"),

    application:set_env(?APP, net_ids, [16#000016, 16#000035]),
    ?assertEqual([16#000016, 16#000035], allowed_net_ids(), "Base 16 numbers"),

    application:set_env(?APP, net_ids, ["000016, 000035"]),
    ?assertEqual(
        [16#000016, 16#000035],
        allowed_net_ids(),
        "Strings numbers get interpreted as base 16"
    ),

    application:set_env(?APP, net_ids, #{16#000016 => test, 16#000035 => test}),
    ?assertEqual(
        [16#000016, 16#000035],
        allowed_net_ids(),
        "Map returns list of configured net ids"
    ),

    ok.

net_id_udp_args_test() ->
    application:set_env(?APP, net_ids, not_a_map),
    ?assertEqual(#{}, net_id_udp_args(35), "Anything not a map returns empty args"),

    application:set_env(?APP, net_ids, #{35 => #{address => "one.two", port => 1122}}),
    ?assertEqual(#{address => "one.two", port => 1122}, net_id_udp_args(35)),

    ok.

-endif.
