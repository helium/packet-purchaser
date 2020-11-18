%%%-------------------------------------------------------------------
%% @doc
%% == LoRaWan Gateway Message Protocol ==
%% See https://github.com/Lora-net/packet_forwarder/blob/master/PROTOCOL.TXT
%% @end
%%%-------------------------------------------------------------------
-module(lorawan_gwmp).

-export([
    push_data/7,
    push_ack/1
]).

-define(PROTOCOL_2, 2).
-define(PUSH_DATA, 0).
-define(PUSH_ACK, 1).
-define(PULL_DATA, 2).
-define(PULL_RESP, 3).
-define(PULL_ACK, 4).
-define(TX_ACK, 5).

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the gateway mainly to forward the RF packets
%% received, and associated metadata, to the server.
%% @end
%%%-------------------------------------------------------------------
-spec push_data(
    non_neg_integer(),
    non_neg_integer(),
    float(),
    binary(),
    float(),
    float(),
    binary()
) -> binary().
push_data(MAC, Tmst, Freq, Datr, RSSI, SNR, Data) ->
    Data = #{
        time => iso8601:format(Tmst),
        tmst => Tmst,
        freq => Freq,
        modu => <<"LORA">>,
        datr => Datr,
        rssi => RSSI,
        lsnr => SNR,
        size => erlang:byte_size(Data),
        data => base64:encode(Data)
    },
    BinJSX = jsx:encode(#{rxpk => [Data]}),
    Token = token(),
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
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_ACK:8/integer-unsigned>>.

%%====================================================================
%% Internal functions
%%====================================================================
-spec token() -> binary().
token() ->
    crypto:strong_rand_bytes(2).
