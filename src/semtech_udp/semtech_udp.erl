%%%-------------------------------------------------------------------
%% @doc
%% == Semtech basic communication protocol between Lora gateway and server ==
%% See https://github.com/Lora-net/packet_forwarder/blob/master/PROTOCOL.TXT
%% @end
%%%-------------------------------------------------------------------
-module(semtech_udp).

-include("semtech_udp.hrl").

-export([
    push_data/3,
    push_ack/1,
    pull_data/2,
    pull_ack/1,
    pull_resp/2,
    tx_ack/2, tx_ack/3,
    token/0,
    token/1,
    identifier/1,
    identifier_to_atom/1,
    json_data/1,
    craft_push_data/2,
    make_join_payload/3
]).

craft_push_data(Payload, MAC0) ->
    Token0 = token(),

    Tmst = erlang:system_time(millisecond),
    Map = #{
        time => iso8601:format(
            calendar:system_time_to_universal_time(Tmst, millisecond)
        ),
        tmst => Tmst band 4294967295,
        freq => 868.1,
        rfch => 0,
        modu => <<"LORA">>,
        datr => <<"SF7BW125">>,
        rssi => -80,
        lsnr => -10,
        size => erlang:byte_size(Payload),
        data => base64:encode(Payload)
    },

    Packet = ?MODULE:push_data(Token0, MAC0, Map),
    {ok, Token0, Packet}.

make_join_payload(AppKey, DevEUI0, DevNonce) ->
    MType = 2#000,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = pp_utils:reverse(AppKey),
    DevEUI = pp_utils:hex_to_bin_lsb(pp_utils:reverse(DevEUI0)),

    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:cmac(aes_cbc128, AppKey, Payload0, 4),
    <<Payload0/binary, MIC:4/binary>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the gateway mainly to forward the RF packets
%% received, and associated metadata, to the server.
%% @end
%%%-------------------------------------------------------------------
-spec push_data(
    binary(),
    binary(),
    map()
) -> binary().
push_data(Token, MAC, Map) ->
    BinJSX = jsx:encode(#{rxpk => [Map]}),
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_DATA:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the server to acknowledge immediately all the
%% PUSH_DATA packets received.
%% @end
%%%-------------------------------------------------------------------
-spec push_ack(binary()) -> binary().
push_ack(Token) ->
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the gateway to poll data from the server.
%% @end
%%%-------------------------------------------------------------------
-spec pull_data(binary(), binary()) -> binary().
pull_data(Token, MAC) ->
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, MAC:8/binary>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the server to confirm that the network route is
%% open and that the server can send PULL_RESP packets at any time.
%% @end
%%%-------------------------------------------------------------------
-spec pull_ack(binary()) -> binary().
pull_ack(Token) ->
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_ACK:8/integer-unsigned>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the server to send RF packets and associated
%% metadata that will have to be emitted by the gateway.
%% @end
%%%-------------------------------------------------------------------
-spec pull_resp(
    binary(),
    map()
) -> binary().
pull_resp(Token, Map) ->
    BinJSX = jsx:encode(#{txpk => Map}),
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_RESP:8/integer-unsigned, BinJSX/binary>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the gateway to send a feedback to the server
%% to inform if a downlink request has been accepted or rejected by the gateway.
%% The datagram may optionnaly contain a JSON string to give more details on
%% acknoledge. If no JSON is present (empty string), this means than no error
%% occured.
%% @end
%%%-------------------------------------------------------------------
-spec tx_ack(
    binary(),
    binary()
) -> binary().
tx_ack(Token, MAC) ->
    tx_ack(Token, MAC, ?TX_ACK_ERROR_NONE).

-spec tx_ack(
    binary(),
    binary(),
    binary()
) -> binary().
tx_ack(Token, MAC, Error) ->
    Map = #{error => Error},
    BinJSX = jsx:encode(#{txpk_ack => Map}),
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?TX_ACK:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>.

-spec token() -> binary().
token() ->
    crypto:strong_rand_bytes(2).

-spec token(binary()) -> binary().
token(<<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, _/binary>>) ->
    Token.

-spec identifier(binary()) -> integer().
identifier(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, Identifier:8/integer-unsigned, _/binary>>
) ->
    Identifier.

-spec identifier_to_atom(non_neg_integer()) -> atom().
identifier_to_atom(?PUSH_DATA) ->
    push_data;
identifier_to_atom(?PUSH_ACK) ->
    push_ack;
identifier_to_atom(?PULL_DATA) ->
    pull_data;
identifier_to_atom(?PULL_RESP) ->
    pull_resp;
identifier_to_atom(?PULL_ACK) ->
    pull_ack;
identifier_to_atom(?TX_ACK) ->
    tx_ack.

-spec json_data(
    binary()
) -> map().
json_data(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?PUSH_DATA:8/integer-unsigned, _MAC:8/binary,
        BinJSX/binary>>
) ->
    jsx:decode(BinJSX);
json_data(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?PULL_RESP:8/integer-unsigned,
        BinJSX/binary>>
) ->
    jsx:decode(BinJSX);
json_data(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?TX_ACK:8/integer-unsigned, _MAC:8/binary,
        BinJSX/binary>>
) ->
    jsx:decode(BinJSX).

%%====================================================================
%% Internal functions
%%====================================================================

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

push_data_test() ->
    Token0 = token(),
    MAC0 = crypto:strong_rand_bytes(8),
    Tmst = erlang:system_time(millisecond),
    Payload = <<"payload">>,
    Map = #{
        time => iso8601:format(
            calendar:system_time_to_universal_time(Tmst, millisecond)
        ),
        tmst => Tmst,
        freq => 915.2,
        rfch => 0,
        modu => <<"LORA">>,
        datr => <<"datr">>,
        rssi => -80.0,
        lsnr => -10,
        size => erlang:byte_size(Payload),
        data => base64:encode(Payload)
    },
    PushData = push_data(Token0, MAC0, Map),
    <<?PROTOCOL_2:8/integer-unsigned, Token1:2/binary, Id:8/integer-unsigned, MAC1:8/binary,
        BinJSX/binary>> = PushData,
    ?assertEqual(Token1, Token0),
    ?assertEqual(?PUSH_DATA, Id),
    ?assertEqual(MAC0, MAC1),
    ?assertEqual(
        #{
            <<"rxpk">> => [
                #{
                    <<"time">> => iso8601:format(
                        calendar:system_time_to_universal_time(Tmst, millisecond)
                    ),
                    <<"tmst">> => Tmst band 4294967295,
                    <<"freq">> => 915.2,
                    <<"rfch">> => 0,
                    <<"modu">> => <<"LORA">>,
                    <<"datr">> => <<"datr">>,
                    <<"rssi">> => -80,
                    <<"lsnr">> => -10,
                    <<"size">> => erlang:byte_size(Payload),
                    <<"data">> => base64:encode(Payload)
                }
            ]
        },
        jsx:decode(BinJSX)
    ),
    ok.

push_ack_test() ->
    Token = token(),
    PushAck = push_ack(Token),
    ?assertEqual(
        <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>,
        PushAck
    ),
    ok.

pull_data_test() ->
    Token = token(),
    MAC = crypto:strong_rand_bytes(8),
    PullData = pull_data(Token, MAC),
    ?assertEqual(
        <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned,
            MAC:8/binary>>,
        PullData
    ),
    ok.

pull_ack_test() ->
    Token = token(),
    PushAck = pull_ack(Token),
    ?assertEqual(
        <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_ACK:8/integer-unsigned>>,
        PushAck
    ),
    ok.

pull_resp_test() ->
    Token0 = token(),
    Map0 = #{
        imme => true,
        freq => 864.123456,
        rfch => 0,
        powe => 14,
        modu => <<"LORA">>,
        datr => <<"SF11BW125">>,
        codr => <<"4/6">>,
        ipol => false,
        size => 32,
        data => <<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>
    },
    PullResp = pull_resp(Token0, Map0),
    <<?PROTOCOL_2:8/integer-unsigned, Token1:2/binary, Id:8/integer-unsigned, BinJSX/binary>> =
        PullResp,
    ?assertEqual(Token1, Token0),
    ?assertEqual(?PULL_RESP, Id),
    ?assertEqual(
        #{
            <<"txpk">> => #{
                <<"imme">> => true,
                <<"freq">> => 864.123456,
                <<"rfch">> => 0,
                <<"powe">> => 14,
                <<"modu">> => <<"LORA">>,
                <<"datr">> => <<"SF11BW125">>,
                <<"codr">> => <<"4/6">>,
                <<"ipol">> => false,
                <<"size">> => 32,
                <<"data">> => <<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>
            }
        },
        jsx:decode(BinJSX)
    ),
    ok.

tx_ack_test() ->
    Token0 = token(),
    MAC0 = crypto:strong_rand_bytes(8),
    TxnAck = tx_ack(Token0, MAC0),
    <<?PROTOCOL_2:8/integer-unsigned, Token1:2/binary, Id:8/integer-unsigned, MAC1:8/binary,
        BinJSX/binary>> =
        TxnAck,
    ?assertEqual(Token0, Token1),
    ?assertEqual(?TX_ACK, Id),
    ?assertEqual(MAC0, MAC1),
    ?assertEqual(
        #{
            <<"txpk_ack">> => #{
                <<"error">> => ?TX_ACK_ERROR_NONE
            }
        },
        jsx:decode(BinJSX)
    ),
    ok.

token_test() ->
    Token = token(),
    ?assertEqual(2, erlang:byte_size(Token)),
    ?assertEqual(Token, token(push_data(Token, crypto:strong_rand_bytes(8), #{}))),
    ?assertEqual(Token, token(push_ack(Token))),
    ?assertEqual(Token, token(pull_data(Token, crypto:strong_rand_bytes(8)))),
    ?assertEqual(Token, token(pull_ack(Token))),
    ?assertEqual(Token, token(pull_resp(Token, #{}))),
    ?assertEqual(Token, token(tx_ack(Token, crypto:strong_rand_bytes(8)))),
    ?assertException(error, function_clause, token(<<"some unknown stuff">>)),
    ok.

identifier_test() ->
    Token = token(),
    ?assertEqual(?PUSH_DATA, identifier(push_data(Token, crypto:strong_rand_bytes(8), #{}))),
    ?assertEqual(?PUSH_ACK, identifier(push_ack(Token))),
    ?assertEqual(?PULL_DATA, identifier(pull_data(Token, crypto:strong_rand_bytes(8)))),
    ?assertEqual(?PULL_ACK, identifier(pull_ack(Token))),
    ?assertEqual(?PULL_RESP, identifier(pull_resp(Token, #{}))),
    ?assertEqual(?TX_ACK, identifier(tx_ack(Token, crypto:strong_rand_bytes(8)))),
    ?assertException(error, function_clause, token(<<"some unknown stuff">>)),
    ok.

identifier_to_atom_test() ->
    ?assertEqual(push_data, identifier_to_atom(?PUSH_DATA)),
    ?assertEqual(push_ack, identifier_to_atom(?PUSH_ACK)),
    ?assertEqual(pull_data, identifier_to_atom(?PULL_DATA)),
    ?assertEqual(pull_resp, identifier_to_atom(?PULL_RESP)),
    ?assertEqual(pull_ack, identifier_to_atom(?PULL_ACK)),
    ?assertEqual(tx_ack, identifier_to_atom(?TX_ACK)),
    ok.

json_data_test() ->
    Token = token(),
    ?assertEqual(
        #{<<"rxpk">> => [#{}]},
        json_data(push_data(Token, crypto:strong_rand_bytes(8), #{}))
    ),
    ?assertEqual(#{<<"txpk">> => #{}}, json_data(pull_resp(Token, #{}))),
    ?assertEqual(
        #{<<"txpk_ack">> => #{<<"error">> => <<"NONE">>}},
        json_data(tx_ack(Token, crypto:strong_rand_bytes(8)))
    ),
    ok.

-endif.
