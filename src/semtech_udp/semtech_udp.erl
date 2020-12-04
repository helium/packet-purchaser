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
    integer(),
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
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_DATA:8/integer-unsigned, MAC:64/integer,
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
    Token0 = token(),
    Tmst = erlang:system_time(millisecond),
    Payload = <<"payload">>,
    PushData = push_data(
        0,
        Tmst,
        915.2,
        <<"datr">>,
        -80.0,
        -10,
        Payload,
        Token0
    ),
    <<?PROTOCOL_2:8/integer-unsigned, Token1:2/binary, Id:8/integer-unsigned, MAC:64/integer,
        BinJSX/binary>> = PushData,
    ?assertEqual(Token1, Token0),
    ?assertEqual(?PUSH_DATA, Id),
    ?assertEqual(0, MAC),
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

token_test() ->
    Token = token(),
    ?assertEqual(2, erlang:byte_size(Token)),
    ?assertEqual(Token, token(push_ack(Token))),
    PushData = push_data(
        0,
        erlang:system_time(millisecond),
        915.2,
        <<"datr">>,
        -80.0,
        -10,
        <<"payload">>,
        Token
    ),
    ?assertEqual(Token, token(PushData)),
    ?assertException(error, function_clause, token(<<"some unknown stuff">>)),
    ok.

identifier_test() ->
    Token = token(),
    ?assertEqual(?PUSH_ACK, identifier(push_ack(Token))),
    PushData = push_data(
        0,
        erlang:system_time(millisecond),
        915.2,
        <<"datr">>,
        -80.0,
        -10,
        <<"payload">>,
        Token
    ),
    ?assertEqual(?PUSH_DATA, identifier(PushData)),
    ?assertException(error, function_clause, token(<<"some unknown stuff">>)),
    ok.

-endif.
