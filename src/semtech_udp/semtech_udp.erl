%%%-------------------------------------------------------------------
%% @doc
%% == Semtech basic communication protocol between Lora gateway and server ==
%% See https://github.com/Lora-net/packet_forwarder/blob/master/PROTOCOL.TXT
%% @end
%%%-------------------------------------------------------------------
-module(semtech_udp).

-include("semtech_udp.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    push_data/8,
    push_ack/1,
    pull_data/2,
    pull_ack/1,
    pull_resp/2,
    pull_resp/2,
    tx_ack/3,
    token/0,
    token/1,
    identifier/1
]).

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the gateway mainly to forward the RF packets
%% received, and associated metadata, to the server.
%% @end
%%%-------------------------------------------------------------------
-spec push_data(
    binary(),
    non_neg_integer(),
    float(),
    string(),
    float(),
    float(),
    binary(),
    binary()
) -> binary().
push_data(MAC, Tmst, Freq, Datr, RSSI, SNR, Payload, Token) ->
    Data = #{
        time => iso8601:format(calendar:system_time_to_universal_time(Tmst, millisecond)),
        tmst => Tmst,
        freq => Freq,
        stat => 0,
        modu => <<"LORA">>,
        datr => Datr,
        rssi => RSSI,
        lsnr => SNR,
        size => erlang:byte_size(Payload),
        data => base64:encode(Payload)
    },
    BinJSX = jsx:encode(#{rxpk => [Data]}),
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
%% TODO: We might need to expand this to add the gateway MAC in there otherwise
%% I don't know where to send donwlink
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
    tx_ack(Token, MAC, <<"NONE">>).

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

%%====================================================================
%% Internal functions
%%====================================================================

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

push_data_test() ->
    MAC0 = crypto:strong_rand_bytes(8),
    Token0 = token(),
    Tmst = erlang:system_time(millisecond),
    Payload = <<"payload">>,
    PushData = push_data(
        MAC0,
        Tmst,
        915.2,
        <<"datr">>,
        -80.0,
        -10,
        Payload,
        Token0
    ),
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
                    <<"tmst">> => Tmst,
                    <<"freq">> => 915.2,
                    <<"stat">> => 0,
                    <<"modu">> => <<"LORA">>,
                    <<"datr">> => <<"datr">>,
                    <<"rssi">> => -80.0,
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
                <<"error">> => <<"NONE">>
            }
        },
        jsx:decode(BinJSX)
    ),
    ok.

token_test() ->
    Token = token(),
    ?assertEqual(2, erlang:byte_size(Token)),
    ?assertEqual(Token, token(push_ack(Token))),
    PushData = push_data(
        crypto:strong_rand_bytes(8),
        erlang:system_time(millisecond),
        915.2,
        <<"datr">>,
        -80.0,
        -10,
        <<"payload">>,
        Token
    ),
    ?assertEqual(Token, token(PushData)),
    ?assertEqual(Token, token(push_ack(Token))),
    ?assertEqual(Token, token(pull_data(Token, crypto:strong_rand_bytes(8)))),
    ?assertEqual(Token, token(pull_ack(Token))),
    ?assertEqual(Token, token(pull_resp(Token, #{}))),
    ?assertEqual(Token, token(tx_ack(Token, crypto:strong_rand_bytes(8)))),
    ?assertException(error, function_clause, token(<<"some unknown stuff">>)),
    ok.

identifier_test() ->
    Token = token(),
    ?assertEqual(?PUSH_ACK, identifier(push_ack(Token))),
    PushData = push_data(
        crypto:strong_rand_bytes(8),
        erlang:system_time(millisecond),
        915.2,
        <<"datr">>,
        -80.0,
        -10,
        <<"payload">>,
        Token
    ),
    ?assertEqual(?PUSH_DATA, identifier(PushData)),
    ?assertEqual(?PUSH_ACK, identifier(push_ack(Token))),
    ?assertEqual(?PULL_DATA, identifier(pull_data(Token, crypto:strong_rand_bytes(8)))),
    ?assertEqual(?PULL_ACK, identifier(pull_ack(Token))),
    ?assertEqual(?PULL_RESP, identifier(pull_resp(Token, #{}))),
    ?assertEqual(?TX_ACK, identifier(tx_ack(Token, crypto:strong_rand_bytes(8)))),
    ?assertException(error, function_clause, token(<<"some unknown stuff">>)),
    ok.

-endif.
