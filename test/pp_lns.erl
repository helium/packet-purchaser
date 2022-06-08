-module(pp_lns).

-behavior(gen_server).

-include("semtech_udp.hrl").
-include("http_protocol.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    delay_next_udp/2,
    delay_next_udp_forever/1,
    pull_resp/5,
    rcv/2, rcv/3,
    not_rcv/3,
    send_packet/2
]).

-export([
    http_rcv/0,
    http_rcv/1,
    not_http_rcv/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([
    handle/2,
    handle_event/3
]).

-define(SERVER, ?MODULE).

-record(state, {
    socket :: gen_udp:socket(),
    port :: inet:port_number(),
    forward :: pid(),
    delay_next_udp = 0 :: integer()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

delay_next_udp_forever(Pid) ->
    gen_server:cast(Pid, {delay_next_udp, timer:seconds(999)}).

delay_next_udp(Pid, Delay) ->
    gen_server:cast(Pid, {delay_next_udp, Delay}).

pull_resp(Pid, IP, Port, Token, Map) ->
    gen_server:cast(Pid, {pull_resp, IP, Port, Token, Map}).

rcv(Pid, Type) ->
    rcv(Pid, Type, timer:seconds(1)).

rcv(Pid, Type, Delay) ->
    receive
        {?MODULE, Pid, Type, Data} -> {ok, Data}
    after Delay -> ct:fail("pp_lns rcv timeout")
    end.

-spec http_rcv() -> {ok, any()}.
http_rcv() ->
    receive
        {http_msg, Payload, Request, {StatusCode, [], RespBody}} ->
            {ok, jsx:decode(Payload), Request, {StatusCode, jsx:decode(RespBody)}}
    after 2500 -> ct:fail(http_msg_timeout)
    end.

-spec http_rcv(map()) -> {ok, any(), any()}.
http_rcv(Expected) ->
    {ok, Got, Request, Response} = ?MODULE:http_rcv(),
    case test_utils:match_map(Expected, Got) of
        true ->
            {ok, Got, Request, Response};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({http_rcv, Reason})
    end.

-spec not_http_rcv(Delay :: integer()) -> ok.
not_http_rcv(Delay) ->
    receive
        {http_msg, _, _} ->
            ct:fail(expected_no_more_http)
    after Delay -> ok
    end.

not_rcv(Pid, Type, Delay) ->
    receive
        {?MODULE, Pid, Type, _Data} ->
            ct:fail("Expected to not receive more")
    after Delay -> ok
    end.

-spec send_packet(PubKeyBin :: libp2p_crypto:pubkey_bin(), Opts :: map()) -> map().
send_packet(PubKeyBin, Opts0) ->
    DefaultOpts = #{
        payload => <<"payload">>,
        rssi => -80.0,
        freq => 904.299,
        dr => "SF10BW125",
        snr => 6.199,
        routing => {devaddr, 16#deadbeef},
        region => 'US915',
        timestamp => erlang:system_time(millisecond)
    },
    Opts1 = maps:merge(DefaultOpts, Opts0),
    Packet = blockchain_helium_packet_v1:new(
        lorawan,
        maps:get(payload, Opts1),
        maps:get(timestamp, Opts1),
        maps:get(rssi, Opts1),
        maps:get(freq, Opts1),
        maps:get(dr, Opts1),
        maps:get(snr, Opts1),
        maps:get(routing, Opts1)
    ),
    SCPacket = blockchain_state_channel_packet_v1:new(
        Packet,
        PubKeyBin,
        maps:get(region, Opts1)
    ),
    ok = pp_sc_packet_handler:handle_packet(
        SCPacket,
        maps:get(timestamp, Opts1),
        self()
    ),
    Opts1.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    Port = maps:get(port, Args),
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}]),
    Pid = maps:get(forward, Args),
    {ok, #state{socket = Socket, port = Port, forward = Pid}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({delay_next_udp, Delay}, State) ->
    lager:info("delaying next udp by ~p", [Delay]),
    {noreply, State#state{delay_next_udp = Delay}};
handle_cast({pull_resp, IP, Port, Token, Map}, #state{socket = Socket} = State) ->
    lager:info("pull_resp ~p", [{IP, Port, Token, Map}]),
    _ = gen_udp:send(Socket, IP, Port, semtech_udp:pull_resp(Token, Map)),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {udp, Socket, IP, Port, Packet},
    #state{socket = Socket} = State
) ->
    ok = handle_udp(IP, Port, Packet, State),
    {noreply, State#state{delay_next_udp = 0}};
handle_info(
    {send, IP, Port, Type, Map, Data},
    #state{socket = Socket, forward = Pid} = State
) ->
    lager:info("sending ~p: ~p / ~p", [Type, Map, Data]),
    Pid ! {?MODULE, self(), Type, Map},
    _ = gen_udp:send(Socket, IP, Port, Data),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{socket = Socket}) ->
    ok = gen_udp:close(Socket),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle_udp(
    IP,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, _MAC:8/binary,
        BinJSX/binary>>,
    #state{delay_next_udp = Delay} = _State
) ->
    lager:info("got PUSH_DATA: ~p, delaying: ~p", [Token, Delay]),
    Map = jsx:decode(BinJSX),
    erlang:send_after(
        Delay,
        self(),
        {send, IP, Port, ?PUSH_DATA, Map, semtech_udp:push_ack(Token)}
    ),
    ok;
handle_udp(
    IP,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, MAC:8/binary>>,
    #state{delay_next_udp = Delay} = _State
) ->
    lager:info("got PULL_DATA: ~p, delaying: ~p", [Token, Delay]),
    erlang:send_after(
        Delay,
        self(),
        {send, IP, Port, ?PULL_DATA, {Token, MAC}, semtech_udp:pull_ack(Token)}
    ),
    ok;
handle_udp(
    _IP,
    _Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?TX_ACK:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>,
    #state{forward = Pid} = _State
) ->
    Map = jsx:decode(BinJSX),
    lager:info("got TX_ACK: ~p", [Token]),
    Pid ! {?MODULE, self(), ?TX_ACK, {Token, MAC, Map}},
    ok;
handle_udp(
    _IP,
    _Port,
    _UnkownUDPPacket,
    _State
) ->
    lager:warning("got an unkown udp packet: ~p  from ~p", [_UnkownUDPPacket, {_IP, _Port}]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle(Req, Args) ->
    Method =
        case elli_request:get_header(<<"Upgrade">>, Req) of
            <<"websocket">> ->
                websocket;
            _ ->
                elli_request:method(Req)
        end,
    ct:pal("~p", [{Method, elli_request:path(Req), Req, Args}]),
    handle(Method, elli_request:path(Req), Req, Args).

%% ------------------------------------------------------------------
%% NOTE: packet-purchaser starts up with a downlink listener
%% using `pp_roaming_downlink' as the handler.
%%
%% Tests using the HTTP protocol start 2 Elli listeners.
%%
%% A forwarding listener :: (fns) Downlink Handler
%% A roaming listener    :: (sns) Uplink Handler as roaming partner
%%
%% The normal downlink listener is started, but ignored.
%%
%% The downlink handler in this file delegates to `pp_roaming_downlink' while
%% sending extra messages to the test running so the production code doesn't
%% need to know about the tests.
%% ------------------------------------------------------------------
handle('POST', [<<"downlink">>], Req, Args) ->
    Forward = maps:get(forward, Args),
    Body = elli_request:body(Req),
    Decoded = jsx:decode(Body),

    SenderNetIDBin = maps:get(<<"SenderID">>, Decoded),
    SenderNetID = pp_utils:hexstring_to_int(SenderNetIDBin),
    FlowType =
        case pp_config:lookup_netid(SenderNetID) of
            {ok, #{protocol := Protocol}} ->
                Protocol#http_protocol.flow_type;
            {error, _} ->
                Forward ! {http_downlink_data_error, {config_not_found, SenderNetIDBin}}
        end,

    case FlowType of
        async ->
            Forward ! {http_downlink_data, Body},
            Res = pp_roaming_downlink:handle(Req, Args),
            ct:pal("Downlink handler resp: ~p", [Res]),
            Forward ! {http_downlink_data_response, 200},
            {200, [], <<>>};
        sync ->
            ct:pal("sync handling downlink:~n~p", [Decoded]),
            Response = pp_roaming_downlink:handle(Req, Args),

            %% ResponseBody = make_response_body(Decoded),
            %% Response = {200, [], jsx:encode(ResponseBody)},
            Forward ! {http_msg, Body, Req, Response},
            Response
    end;
handle('POST', [<<"uplink">>], Req, Args) ->
    Forward = maps:get(forward, Args),
    Body = elli_request:body(Req),
    Decoded = jsx:decode(Body),

    ReceiverNetIDBin = maps:get(<<"ReceiverID">>, Decoded),
    ReceiverNetID = pp_utils:hexstring_to_int(ReceiverNetIDBin),
    {ok, #{protocol := #http_protocol{flow_type = FlowType}}} = pp_config:lookup_netid(
        ReceiverNetID
    ),

    ResponseBody =
        case maps:get(response, Args, undefined) of
            undefined ->
                make_response_body(jsx:decode(Body));
            Resp ->
                ct:pal("Using canned response: ~p", [Resp]),
                Resp
        end,

    case FlowType of
        async ->
            Response = {200, [], <<>>},
            Forward ! {http_uplink_data, Body},
            Forward ! {http_uplink_data_response, 200},
            spawn(fun() ->
                timer:sleep(250),
                Res = hackney:post(
                    <<"http://127.0.0.1:3003/downlink">>,
                    [{<<"Host">>, <<"localhost">>}],
                    jsx:encode(ResponseBody),
                    [with_body]
                ),
                ct:pal("Downlink Res: ~p", [Res])
            end),

            Response;
        sync ->
            Response = {200, [], jsx:encode(ResponseBody)},
            Forward ! {http_msg, Body, Req, Response},

            Response
    end.

handle_event(_Event, _Data, _Args) ->
    %% uncomment for Elli errors.
    %% ct:print("Elli Event (~p):~nData~n~p~nArgs~n~p", [_Event, _Data, _Args]),
    ok.

make_response_body(#{
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"MessageType">> := <<"PRStartReq">>,
    <<"ReceiverID">> := ReceiverID,
    <<"SenderID">> := SenderID,
    <<"TransactionID">> := TransactionID,
    <<"ULMetaData">> := #{
        <<"ULFreq">> := Freq,
        <<"DevEUI">> := DevEUI,
        <<"FNSULToken">> := Token
    }
}) ->
    %% Join Response
    %% includes similar information from XmitDataReq
    #{
        'ProtocolVersion' => ProtocolVersion,
        'SenderID' => ReceiverID,
        'ReceiverID' => SenderID,
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartAns">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'PHYPayload' => pp_utils:binary_to_hexstring(<<"join_accept_payload">>),
        'DevEUI' => DevEUI,

        %% 11.3.1 Passive Roaming Start
        %% Step 6: stateless fNS operation
        'DLMetaData' => #{
            'DLFreq1' => Freq,
            'DataRate1' => 1,
            'FNSULToken' => Token,
            'Lifetime' => 0
        }
    };
make_response_body(#{
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"ReceiverID">> := ReceiverID,
    <<"TransactionID">> := TransactionID
}) ->
    %% Ack to regular uplink
    #{
        'ProtocolVersion' => ProtocolVersion,
        'SenderID' => ReceiverID,
        'ReceiverID' => <<"0xC00053">>,
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartAns">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        %% 11.3.1 Passive Roaming Start
        %% Step 6: stateless fNS operation
        'Lifetime' => 0
    }.
