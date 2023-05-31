-module(pp_packet_reporter).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    report_packet/4
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-ifdef(TEST).

-export([
    get_bucket/1,
    get_client/1
]).

-endif.

-define(SERVER, ?MODULE).
-define(UPLOAD, upload).

-record(state, {
    bucket :: binary(),
    bucket_region :: binary(),
    report_max_size :: non_neg_integer(),
    report_interval :: non_neg_integer(),
    current_packets = [] :: [binary()],
    current_size = 0 :: non_neg_integer()
}).

-type state() :: #state{}.

-type packet_reporter_opts() :: #{
    aws_bucket => binary(),
    aws_bucket_region => binary(),
    report_interval => non_neg_integer(),
    report_max_size => non_neg_integer()
}.

%% ------------------------------------------------------------------
%%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(packet_reporter_opts()) -> any().
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec report_packet(
    Packet :: pp_packet_up:packet(),
    NetID :: non_neg_integer(),
    PacketType :: join | packet | uplink,
    ReceivedTimestamp :: non_neg_integer()
) -> ok.
report_packet(Packet, NetID, packet, ReceivedTimestamp) ->
    report_packet(Packet, NetID, uplink, ReceivedTimestamp);
report_packet(Packet, NetID, PacketType, ReceivedTimestamp) ->
    EncodedPacket = encode_packet(Packet, NetID, pp_utils:get_oui(), PacketType, ReceivedTimestamp),
    gen_server:cast(?SERVER, {report_packet, EncodedPacket}).

%% ------------------------------------------------------------------
%%% Test Function Definitions
%% ------------------------------------------------------------------

-ifdef(TEST).

-spec get_bucket(state()) -> binary().
get_bucket(#state{bucket = Bucket}) ->
    Bucket.

-spec get_client(state()) -> aws_client:aws_client().
get_client(State) ->
    setup_aws(State).

-endif.

%% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(packet_reporter_opts()) -> {ok, state()}.
init(
    #{
        aws_bucket := Bucket,
        aws_bucket_region := BucketRegion,
        report_max_size := MaxSize,
        report_interval := Interval
    } = Args
) ->
    lager:info(maps:to_list(Args), "started"),
    ok = schedule_upload(Interval),
    {ok, #state{
        bucket = Bucket,
        bucket_region = BucketRegion,
        report_max_size = MaxSize,
        report_interval = Interval
    }}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(
    {report_packet, EncodedPacket},
    #state{report_max_size = MaxSize, current_packets = Packets, current_size = Size} = State
) when Size < MaxSize ->
    {noreply, State#state{
        current_packets = [EncodedPacket | Packets],
        current_size = erlang:size(EncodedPacket) + Size
    }};
handle_cast(
    {report_packet, EncodedPacket},
    #state{report_max_size = MaxSize, current_packets = Packets, current_size = Size} = State
) when Size >= MaxSize ->
    lager:info("got packet, size too big"),
    {noreply,
        upload(State#state{
            current_packets = [EncodedPacket | Packets],
            current_size = erlang:size(EncodedPacket) + Size
        })};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(?UPLOAD, #state{report_interval = Interval} = State) ->
    lager:info("upload time"),
    ok = schedule_upload(Interval),
    {noreply, upload(State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{current_packets = Packets}) ->
    lager:error("terminate ~p, dropped ~w packets", [_Reason, erlang:length(Packets)]),
    ok.

%% ------------------------------------------------------------------
%%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec encode_packet(
    Packet :: pp_packet_up:packet(),
    NetID :: non_neg_integer(),
    OUI :: non_neg_integer(),
    PacketType :: join | uplink,
    ReceivedTimestamp :: non_neg_integer()
) -> binary().
encode_packet(Packet, NetID, OUI, PacketType, ReceivedTimestamp) ->
    EncodedPacket = pp_packet_report:encode(
        pp_packet_report:new(Packet, NetID, OUI, PacketType, ReceivedTimestamp)
    ),
    PacketSize = erlang:size(EncodedPacket),
    <<PacketSize:32/big-integer-unsigned, EncodedPacket/binary>>.

-spec setup_aws(state()) -> aws_client:aws_client().
setup_aws(#state{
    bucket_region = <<"local">>
}) ->
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret
    } = aws_credentials:get_credentials(),
    {LocalHost, LocalPort} = get_local_host_port(),
    aws_client:make_local_client(AccessKey, Secret, LocalPort, LocalHost);
setup_aws(#state{
    bucket_region = BucketRegion
}) ->
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret,
        token := Token
    } = aws_credentials:get_credentials(),
    aws_client:make_temporary_client(AccessKey, Secret, Token, BucketRegion).

-spec upload(state()) -> state().
upload(#state{current_packets = []} = State) ->
    lager:info("nothing to upload"),
    State;
upload(
    #state{
        bucket = Bucket,
        current_packets = Packets,
        current_size = Size
    } = State
) ->
    StartTime = erlang:system_time(millisecond),
    AWSClient = setup_aws(State),

    Timestamp = erlang:system_time(millisecond),
    FileName = erlang:list_to_binary("packetreport." ++ erlang:integer_to_list(Timestamp) ++ ".gz"),
    Compressed = zlib:gzip(Packets),

    MD = [
        {filename, erlang:binary_to_list(FileName)},
        {bucket, erlang:binary_to_list(Bucket)},
        {packet_cnt, erlang:length(Packets)},
        {gzip_bytes, erlang:size(Compressed)},
        {bytes, Size}
    ],
    lager:info(MD, "uploading report"),
    case
        aws_s3:put_object(
            AWSClient,
            Bucket,
            FileName,
            #{
                <<"Body">> => Compressed
            }
        )
    of
        {ok, _, _Response} ->
            lager:info(MD, "upload success"),
            ok = pp_metrics:observe_packet_report(ok, StartTime),
            State#state{current_packets = [], current_size = 0};
        _Error ->
            lager:error(MD, "upload failed ~p", [_Error]),
            ok = pp_metrics:observe_packet_report(error, StartTime),
            State
    end.

-spec schedule_upload(Interval :: non_neg_integer()) -> ok.
schedule_upload(Interval) ->
    _ = erlang:send_after(Interval, self(), ?UPLOAD),
    ok.

-spec get_local_host_port() -> {binary(), binary()}.
get_local_host_port() ->
    get_local_host_port(
        os:getenv("PP_PACKET_REPORTER_LOCAL_HOST", []),
        os:getenv("PP_PACKET_REPORTER_LOCAL_PORT", [])
    ).

-spec get_local_host_port(Host :: string() | binary(), Port :: string() | binary()) ->
    {binary(), binary()}.
get_local_host_port([], []) ->
    {<<"localhost">>, <<"4566">>};
get_local_host_port([], Port) ->
    get_local_host_port(<<"localhost">>, Port);
get_local_host_port(Host, []) ->
    get_local_host_port(Host, <<"4566">>);
get_local_host_port(Host, Port) when is_list(Host) ->
    get_local_host_port(erlang:list_to_binary(Host), Port);
get_local_host_port(Host, Port) when is_list(Port) ->
    get_local_host_port(Host, erlang:list_to_binary(Port));
get_local_host_port(Host, Port) when is_binary(Host) andalso is_binary(Port) ->
    {Host, Port}.
