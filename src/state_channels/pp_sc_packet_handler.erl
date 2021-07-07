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
    should_accept_join/1,
    join_eui_to_net_id/1,
    allowed_net_ids/0,
    net_id_udp_args/1
]).

%% Offer rejected reasons
-define(UNMAPPED_EUI, unmapped_eui).
-define(NET_ID_REJECTED, net_id_rejected).
%% -define(NET_ID_INVALID, net_id_invalid).

%% ------------------------------------------------------------------
%% Packet Handler Functions
%% ------------------------------------------------------------------

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok.
handle_offer(Offer, _HandlerPid) ->
    #routing_information_pb{data = Routing} = blockchain_state_channel_offer_v1:routing(Offer),
    Resp =
        case Routing of
            {eui, EUI} -> handle_join_offer(EUI, Offer);
            {devaddr, DevAddr} -> handle_packet_offer(DevAddr, Offer)
        end,
    erlang:spawn(fun() ->
        handle_offer_resp(Routing, Offer, Resp)
    end),
    Resp.

-spec handle_packet(blockchain_state_channel_packet_v1:packet(), pos_integer(), pid()) -> ok.
handle_packet(SCPacket, _PacketTime, Pid) ->
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
            tmst => Tmst band 16#FFFFFFFF,
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

    case blockchain_helium_packet_v1:routing_info(Packet) of
        {devaddr, DevAddr} ->
            try
                {ok, NetID} = lorawan_devaddr:net_id(<<DevAddr:32/integer-unsigned>>),
                lager:debug(
                    "Packet [Devaddr: ~p] [NetID: ~p]",
                    [DevAddr, NetID]
                ),
                case pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, net_id_udp_args(NetID)) of
                    {ok, WorkerPid} ->
                        ok = pp_metrics:handle_packet(PubKeyBin, NetID),
                        pp_udp_worker:push_data(WorkerPid, Token, UDPData, Pid);
                    {error, _Reason} = Error ->
                        lager:error(
                            "failed to start udp connector for ~p: ~p",
                            [blockchain_utils:addr2name(PubKeyBin), _Reason]
                        ),
                        Error
                end
            catch
                error:{badkey, KeyNetID} ->
                    lager:debug("packet: ignoring unconfigured NetID ~p", [KeyNetID])
            end;
        {eui, _, _} = EUI ->
            try
                {ok, NetID} = join_eui_to_net_id(EUI),
                lager:debug(
                    "Packet [EUI: ~p] [NetID: ~p] ~p",
                    [EUI, NetID]
                ),
                case pp_udp_sup:maybe_start_worker({PubKeyBin, NetID}, net_id_udp_args(NetID)) of
                    {ok, WorkerPid} ->
                        pp_udp_worker:push_data(WorkerPid, Token, UDPData, Pid);
                    {error, _Reason} = Error ->
                        lager:error(
                            "failed to start udp connector for ~p: ~p",
                            [blockchain_utils:addr2name(PubKeyBin), _Reason]
                        ),
                        Error
                end
            catch
                error:{badkey, KeyNetID} ->
                    lager:debug("join: ignoring unconfigured NetID ~p", [KeyNetID]);
                error:{badmatch, {error, no_mapping}} ->
                    lager:debug("join: ignoring no mapping for EUI ~p", [EUI])
            end
    end.

%% ------------------------------------------------------------------
%% Buying Functions
%% ------------------------------------------------------------------

handle_join_offer(EUI, Offer) ->
    case join_eui_to_net_id(EUI) of
        {error, _} ->
            {error, ?UNMAPPED_EUI};
        {ok, NetID} ->
            pp_multi_buy:maybe_buy_offer(Offer, NetID)
    end.

handle_packet_offer(DevAddr, Offer) ->
    case allowed_net_ids() of
        allow_all ->
            ok;
        IDs ->
            case lorawan_devaddr:net_id(<<DevAddr:32/integer-unsigned>>) of
                {ok, NetID} ->
                    case lists:member(NetID, IDs) of
                        true -> pp_multi_buy:maybe_buy_offer(Offer, NetID);
                        false -> {error, ?NET_ID_REJECTED}
                    end;
                Err ->
                    Err
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle_offer_resp(Routing, Offer, ok) ->
    PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),
    case Routing of
        {eui, EUI} ->
            {ok, NetID} = join_eui_to_net_id(EUI),
            ok = pp_metrics:handle_offer(PubKeyBin, NetID),
            lager:debug("offer: buying join [EUI: ~p]", [EUI]);
        {devaddr, DevAddr} ->
            {ok, NetID} = lorawan_devaddr:net_id(<<DevAddr:32/integer-unsigned>>),
            ok = pp_metrics:handle_offer(PubKeyBin, NetID),
            lager:debug("offer: buying packet [DevAddr: ~p] [NetID: ~p]", [DevAddr, NetID])
    end;
handle_offer_resp(Routing, _Offer, {error, Err}) ->
    case Routing of
        {eui, EUI} ->
            lager:warning("offer: ignoring join [EUI: ~p] [Err: ~p]", [EUI, Err]);
        {devaddr, DevAddr} ->
            lager:warning("offer: ignoring packet [Devaddr: ~p] [Err: ~p]", [DevAddr, Err])
    end.

-spec should_accept_join(#eui_pb{}) -> boolean().
should_accept_join(#eui_pb{} = EUI) ->
    case join_eui_to_net_id(EUI) of
        {error, _} -> false;
        {ok, _} -> true
    end.

-spec join_eui_to_net_id(#eui_pb{} | {eui, non_neg_integer(), non_neg_integer()}) ->
    {ok, non_neg_integer()} | {error, no_mapping}.
join_eui_to_net_id(#eui_pb{deveui = Dev, appeui = App}) ->
    join_eui_to_net_id({eui, Dev, App});
join_eui_to_net_id({eui, DevEUI, AppEUI}) ->
    Map = application:get_env(?APP, join_net_ids, #{}),

    case maps:get({DevEUI, AppEUI}, Map, maps:get({'*', AppEUI}, Map, undefined)) of
        undefined ->
            {error, no_mapping};
        NetID ->
            {ok, NetID}
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

should_accept_join_test() ->
    Dev1 = 7,
    App1 = 13,
    Dev2 = 13,
    App2 = 17,
    EUI1 = #eui_pb{deveui = Dev1, appeui = App1},
    EUI2 = #eui_pb{deveui = Dev2, appeui = App2},

    NoneMapped = #{},
    OneMapped = #{{Dev1, App1} => 2},
    BothMapped = #{{Dev1, App1} => 2, {Dev2, App2} => 99},
    WildcardMapped = #{{'*', App1} => 2, {'*', App2} => 99},

    application:set_env(?APP, join_net_ids, NoneMapped),
    ?assertEqual(false, should_accept_join(EUI1), "Empty mapping, no joins"),

    application:set_env(?APP, join_net_ids, OneMapped),
    ?assertEqual(true, should_accept_join(EUI1), "One EUI mapping, this one"),
    ?assertEqual(false, should_accept_join(EUI2), "One EUI mapping, not this one"),

    application:set_env(?APP, join_net_ids, BothMapped),
    ?assertEqual(true, should_accept_join(EUI1), "All EUI Mapped 1"),
    ?assertEqual(true, should_accept_join(EUI2), "All EUI Mapped 2"),

    application:set_env(?APP, join_net_ids, WildcardMapped),
    ?assertEqual(true, should_accept_join(EUI1), "Wildcard EUI Mapped 1"),
    ?assertEqual(
        true,
        should_accept_join(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = App1
            }
        ),
        "Wildcard random device EUI Mapped 1"
    ),
    ?assertEqual(true, should_accept_join(EUI2), "Wildcard EUI Mapped 2"),
    ?assertEqual(
        true,
        should_accept_join(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = App2
            }
        ),
        "Wildcard random device EUI Mapped 2"
    ),
    ?assertEqual(
        false,
        should_accept_join(
            #eui_pb{
                deveui = rand:uniform(trunc(math:pow(2, 64) - 1)),
                appeui = rand:uniform(trunc(math:pow(2, 64) - 1000)) + 1000
            }
        ),
        "Wildcard random device EUI and unknown join eui no joins"
    ),

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
