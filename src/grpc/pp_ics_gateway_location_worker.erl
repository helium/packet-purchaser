%%%-------------------------------------------------------------------
%% @doc
%% == Packet Purchaser IOT Config Service Gateway Location Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(pp_ics_gateway_location_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init_ets/0,
    get/1
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

-define(ICS_CHANNEL, ics_channel).
-define(SERVER, ?MODULE).
-define(ETS, pp_ics_gateway_location_worker_ets).
-define(INIT, init).
-ifdef(TEST).
-define(BACKOFF_MIN, 100).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: function(),
    transport :: http | https,
    host :: string(),
    port :: non_neg_integer(),
    conn_backoff :: backoff:backoff()
}).

-record(location, {
    gateway :: libp2p_crypto:pubkey_bin(),
    timestamp :: non_neg_integer(),
    h3_index :: h3:index()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    case start_link_args(Args) of
        ignore ->
            lager:warning("~s ignored ~p", [?MODULE, Args]),
            ignore;
        Map ->
            gen_server:start_link({local, ?SERVER}, ?SERVER, Map, [])
    end.

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {keypos, #location.gateway}
    ]),
    ok.

-spec get(libp2p_crypto:pubkey_bin()) -> {ok, h3:index()} | {error, any()}.
get(PubKeyBin) ->
    case lookup(PubKeyBin) of
        {error, _Reason} ->
            gen_server:call(?SERVER, {get, PubKeyBin});
        {ok, _} = OK ->
            OK
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(
    #{
        pubkey_bin := PubKeyBin,
        sig_fun := SigFun,
        transport := Transport,
        host := Host,
        port := Port
    } = Args
) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    %% self() ! ?INIT,
    {ok, #state{
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        transport = Transport,
        host = Host,
        port = Port,
        conn_backoff = Backoff
    }}.

handle_call({get, PubKeyBin}, _From, #state{conn_backoff = Backoff0} = State) ->
    HotspotName = pp_utils:animal_name(PubKeyBin),
    case get_gateway_location(PubKeyBin, State) of
        {error, Reason, true} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?INIT),
            lager:warning(
                "failed to get_gateway_location ~p for ~s, reconnecting in ~wms",
                [Reason, HotspotName, Delay]
            ),
            {reply, {error, Reason}, State#state{conn_backoff = Backoff1}};
        {error, Reason, false} ->
            lager:warning("failed to get_gateway_location ~p for ~s", [Reason, HotspotName]),
            {reply, {error, Reason}, State};
        {ok, H3IndexString} ->
            H3Index = h3:from_string(H3IndexString),
            ok = insert(PubKeyBin, H3Index),
            {reply, {ok, H3Index}, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec lookup(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, h3:index()} | {error, not_found | outdated}.
lookup(PubKeyBin) ->
    Yesterday = erlang:system_time(millisecond) - timer:hours(24),
    case ets:lookup(?ETS, PubKeyBin) of
        [] ->
            {error, not_found};
        [#location{timestamp = T}] when T < Yesterday ->
            {error, outdated};
        [#location{h3_index = H3Index}] ->
            {ok, H3Index}
    end.

-spec insert(PubKeyBin :: libp2p_crypto:pubkey_bin(), H3Index :: h3:index()) -> ok.
insert(PubKeyBin, H3Index) ->
    true = ets:insert(?ETS, #location{
        gateway = PubKeyBin,
        timestamp = erlang:system_time(millisecond),
        h3_index = H3Index
    }),
    ok.

%% We have to do this because the call to `helium_iot_config_gateway_client:location` can return
%% `{error, {Status, Reason}, _}` but is not in the spec... [from router]
-dialyzer({nowarn_function, get_gateway_location/2}).

-spec get_gateway_location(PubKeyBin :: libp2p_crypto:pubkey_bin(), state()) ->
    {ok, string()} | {error, any(), boolean()}.
get_gateway_location(PubKeyBin, #state{sig_fun = SigFun}) ->
    Req = #{
        gateway => PubKeyBin
    },
    EncodedReq = iot_config_client_pb:encode_msg(Req, gateway_location_req_v1_pb),
    SignedReq = Req#{signature => SigFun(EncodedReq)},
    case
        helium_iot_config_gateway_client:location(SignedReq, #{
            channel => channel()
        })
    of
        {error, {Status, Reason}, _} when erlang:is_binary(Status) ->
            {error, {grpcbox_utils:status_to_string(Status), Reason}, false};
        {grpc_error, Reason} ->
            {error, Reason, false};
        {error, Reason} ->
            {error, Reason, true};
        {ok, #{location := Location}, _Meta} ->
            {ok, Location}
    end.

%% ------------------------------------------------------------------
%% Config Service gen_server utils
%% ------------------------------------------------------------------

-spec start_link_args(map()) -> ignore | map().
start_link_args(#{transport := ""}) ->
    ignore;
start_link_args(#{host := ""}) ->
    ignore;
start_link_args(#{port := ""}) ->
    ignore;
start_link_args(#{transport := "http"} = Args) ->
    start_link_args(Args#{transport => http});
start_link_args(#{transport := "https"} = Args) ->
    start_link_args(Args#{transport => https});
start_link_args(#{port := Port} = Args) when is_list(Port) ->
    start_link_args(Args#{port => erlang:list_to_integer(Port)});
start_link_args(#{transport := Transport, host := Host, port := Port} = Args) when
    is_atom(Transport) andalso is_list(Host) andalso is_integer(Port)
->
    Args;
start_link_args(_) ->
    ignore.

channel() ->
    ?ICS_CHANNEL.
