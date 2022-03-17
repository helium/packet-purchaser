-module(pp_downlink).

-export([
    init_ets/0,
    insert_handler/2,
    delete_handler/1,
    lookup_handler/1,
    make_uplink_token/3
]).

-define(ETS, pp_downlink_ets).

-define(TOKEN_SEP, <<":">>).

-export([
    handle/2,
    handle_event/3
]).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ok.

-spec insert_handler(PubKeyBin :: binary(), SCPid :: pid()) -> ok.
insert_handler(PubKeyBin, SCPid) ->
    true = ets:insert(?ETS, {PubKeyBin, SCPid}),
    ok.

-spec delete_handler(PubKeyBin :: binary()) -> ok.
delete_handler(PubKeyBin) ->
    true = ets:delete(?ETS, PubKeyBin),
    ok.

-spec lookup_handler(PubKeyBin :: binary()) -> {ok, SCPid :: pid}.
lookup_handler(PubKeyBin) ->
    [{_, SCPid}] = ets:lookup(?ETS, PubKeyBin),
    {ok, SCPid}.

handle(Req, Args) ->
    Method = elli_request:method(Req),

    ct:pal("~p", [{Method, elli_request:path(Req), Req, Args}]),

    Body = elli_request:body(Req),
    Decoded = jsx:decode(Body),

    #{
        <<"TransactionID">> := TransactionID,
        <<"SenderID">> := SenderID,
        <<"PHYPayload">> := Payload,
        <<"DLMetaData">> := #{
            <<"FNSULToken">> := Token,
            <<"DataRate1">> := DR,
            <<"DLFreq1">> := Frequency,
            <<"RXDelay1">> := Delay,
            <<"GWInfo">> := [#{<<"ULToken">> := _ULToken}]
        }
    } = Decoded,

    {ok, PubKeyBin, Region, PacketTime} = parse_uplink_token(Token),

    {ok, SCPid} = ?MODULE:lookup_handler(PubKeyBin),

    DataRate = pp_lorawan:dr_to_datar(Region, DR),

    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        base64:decode(pp_utils:hexstring_to_binary(Payload)),
        _SignalStrength = 27,
        %% FIXME: Make sure this is the correct resolution
        PacketTime + Delay,
        Frequency,
        DataRate,
        _RX2 = undefined
    ),
    SCResp = blockchain_state_channel_response_v1:new(true, DownlinkPacket),

    ok = blockchain_state_channel_common:send_response(SCPid, SCResp),

    {200, [],
        jsx:encode(#{
            'ProtocolVersion' => <<"1.0">>,
            'MessageType' => <<"XmitDataAns">>,
            'ReceiverID' => SenderID,
            'SenderID' => <<"0xC00053">>,
            'Result' => #{'ResultCode' => <<"Success">>},
            'TransactionID' => TransactionID,
            'DLFreq1' => Frequency
        })}.

handle_event(_Event, _Data, _Args) ->
    ok.

make_uplink_token(PubKeyBin, Region, PacketTime) ->
    Parts = [
        libp2p_crypto:bin_to_b58(PubKeyBin),
        erlang:atom_to_binary(Region),
        erlang:integer_to_binary(PacketTime)
    ],
    Token0 = lists:join(?TOKEN_SEP, Parts),
    Token1 = erlang:iolist_to_binary(Token0),
    pp_utils:binary_to_hexstring(Token1).

parse_uplink_token(<<"0x", Token/binary>>) ->
    Bin = pp_utils:hex_to_binary(Token),
    [B58, RegionBin, PacketTimeBin] = binary:split(Bin, ?TOKEN_SEP, [global]),
    PubKeyBin = libp2p_crypto:b58_to_bin(erlang:binary_to_list(B58)),
    Region = erlang:binary_to_existing_atom(RegionBin),
    PacketTime = erlang:binary_to_integer(PacketTimeBin),
    {ok, PubKeyBin, Region, PacketTime}.
