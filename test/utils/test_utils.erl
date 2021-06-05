-module(test_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("packet_purchaser.hrl").

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    match_map/2,
    wait_until/1, wait_until/3
]).

-spec init_per_testcase(atom(), list()) -> list().
init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(blockchain, base_dir, BaseDir ++ "/blockchain_data"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    ok = application:set_env(lager, crash_log, "crash.log"),
    FormatStr = [
        "[",
        date,
        " ",
        time,
        "] ",
        pid,
        " [",
        severity,
        "]",
        {device_id, [" [", device_id, "]"], ""},
        " [",
        {module, ""},
        {function, [":", function], ""},
        {line, [":", line], ""},
        "] ",
        message,
        "\n"
    ],
    case os:getenv("CT_LAGER", "NONE") of
        "DEBUG" ->
            ok = application:set_env(lager, handlers, [
                {lager_console_backend, [
                    {level, error},
                    {formatter_config, FormatStr}
                ]},
                {lager_file_backend, [
                    {file, "packet_purchaser.log"},
                    {level, error},
                    {formatter_config, FormatStr}
                ]}
            ]),
            ok = application:set_env(lager, traces, [
                {lager_console_backend, [{application, packet_purchaser}], debug},
                {{lager_file_backend, "packet_purchaser.log"}, [{application, router}], debug}
            ]);
        _ ->
            ok
    end,

    {ok, _} = application:ensure_all_started(?APP),

    SwarmKey = filename:join([
        application:get_env(blockchain, base_dir, "data"),
        "blockchain",
        "swarm_key"
    ]),
    ok = filelib:ensure_dir(SwarmKey),
    {ok, PPKeys} = libp2p_crypto:load_keys(SwarmKey),
    #{public := PPPubKey, secret := PPPrivKey} = PPKeys,
    {ok, _GenesisMembers, ConsensusMembers, _Keys} = blockchain_test_utils:init_chain(
        5000,
        [{PPPrivKey, PPPubKey}]
    ),

    {ok, FakeLNSPid} = pp_lns:start_link(#{port => 1700, forward => self()}),
    {PubKeyBin, WorkerPid} = start_gateway(),

    DefaultEnv = application:get_all_env(?APP),
    ResetEnvFun = fun() ->
        [application:set_env(?APP, Key, Val) || {Key, Val} <- DefaultEnv],
        ok
    end,

    lager:info("starting test ~p", [TestCase]),
    [
        {lns, FakeLNSPid},
        {gateway, {PubKeyBin, WorkerPid}},
        {consensus_member, ConsensusMembers},
        {reset_env_fun, ResetEnvFun}
        | Config
    ].

-spec end_per_testcase(atom(), list()) -> ok.
end_per_testcase(TestCase, Config) ->
    lager:info("stopping test ~p", [TestCase]),
    FakeLNSPid = proplists:get_value(lns, Config),
    ResetEnvFun = proplists:get_value(reset_env_fun, Config),
    ok = ResetEnvFun(),
    ok = gen_server:stop(FakeLNSPid),
    ok = application:stop(?APP),
    ok = application:stop(lager),
    ok.

-spec match_map(map(), any()) -> true | {false, term()}.
match_map(Expected, Got) when is_map(Got) ->
    case maps:size(Expected) == maps:size(Got) of
        false ->
            {false, {size_mismatch, maps:size(Expected), maps:size(Got)}};
        true ->
            maps:fold(
                fun
                    (_K, _V, {false, _} = Acc) ->
                        Acc;
                    (K, V, true) when is_function(V) ->
                        case V(maps:get(K, Got, undefined)) of
                            true ->
                                true;
                            false ->
                                {false, {value_predicate_failed, K, maps:get(K, Got, undefined)}}
                        end;
                    (K, '_', true) ->
                        case maps:is_key(K, Got) of
                            true -> true;
                            false -> {false, {missing_key, K}}
                        end;
                    (K, V, true) when is_map(V) ->
                        match_map(V, maps:get(K, Got, #{}));
                    (K, V0, true) when is_list(V0) ->
                        V1 = lists:zip(lists:seq(1, erlang:length(V0)), lists:sort(V0)),
                        G0 = maps:get(K, Got, []),
                        G1 = lists:zip(lists:seq(1, erlang:length(G0)), lists:sort(G0)),
                        match_map(maps:from_list(V1), maps:from_list(G1));
                    (K, V, true) ->
                        case maps:get(K, Got, undefined) of
                            V -> true;
                            _ -> {false, {value_mismatch, K, V, maps:get(K, Got, undefined)}}
                        end
                end,
                true,
                Expected
            )
    end;
match_map(_Expected, _Got) ->
    {false, not_map}.

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_gateway() -> {libp2p_crypto:pubkeybin(), pid()}.
start_gateway() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    {ok, WorkerPid} = pp_udp_sup:maybe_start_worker(PubKeyBin, #{}),
    {PubKeyBin, WorkerPid}.
