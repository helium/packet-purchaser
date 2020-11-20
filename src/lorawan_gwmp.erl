%%%-------------------------------------------------------------------
%% @doc
%% == LoRaWan Gateway Message Protocol ==
%% See https://github.com/Lora-net/packet_forwarder/blob/master/PROTOCOL.TXT
%% @end
%%%-------------------------------------------------------------------
-module(lorawan_gwmp).

-include("lorawan_gwmp.hrl").

-export([
    push_data/7,
    push_ack/1
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
    binary()
) -> binary().
push_data(MAC, Tmst, Freq, Datr, RSSI, SNR, Payload) ->
    Data = #{
        time => iso8601:format(calendar:system_time_to_universal_time(Tmst, millisecond)),
        tmst => Tmst,
        freq => Freq,
        modu => <<"LORA">>,
        datr => Datr,
        rssi => RSSI,
        lsnr => SNR,
        size => erlang:byte_size(Payload),
        data => base64:encode(Payload)
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
