%%%-------------------------------------------------------------------
%% @doc
%% == Semtech basic communication protocol between Lora gateway and server ==
%% See https://github.com/Lora-net/packet_forwarder/blob/master/PROTOCOL.TXT
%% @end
%%%-------------------------------------------------------------------
-module(semtech_udp).

-include("semtech_udp.hrl").

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
