-module(test_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("packet_purchaser.hrl").

-export([
    init_per_testcase/2,
    match_map/2,
    end_per_testcase/2
]).

-spec init_per_testcase(atom(), list()) -> list().
init_per_testcase(TestCase, Config) ->
    case os:getenv("CT_LAGER", "NONE") of
        "DEBUG" ->
            FormatStr = [
                "[",
                erlang:atom_to_list(TestCase),
                "] ",
                "[",
                date,
                " ",
                time,
                "] ",
                pid,
                " [",
                severity,
                "]",
                {gateway_id, [" [", gateway_id, "]"], ""},
                " [",
                {module, ""},
                {function, [":", function], ""},
                {line, [":", line], ""},
                "] ",
                message,
                "\n"
            ],
            ok = application:set_env(lager, handlers, [
                {lager_console_backend, [
                    {level, debug},
                    {formatter_config, FormatStr}
                ]}
            ]);
        _ ->
            ok = application:set_env(lager, log_root, "/log")
    end,
    ok = application:set_env(?APP, ?UDP_WORKER, [{address, {127, 0, 0, 1}}, {port, 1680}]),
    {ok, _} = application:ensure_all_started(?APP),
    {ok, FakeLNSPid} = fake_lns:start_link(#{port => 1680, forward => self()}),
    {PubKeyBin, WorkerPid} = start_gateway(),
    lager:info("starting test ~p", [TestCase]),
    [{fake_lns, FakeLNSPid}, {gateway, {PubKeyBin, WorkerPid}} | Config].

-spec end_per_testcase(atom(), list()) -> ok.
end_per_testcase(TestCase, Config) ->
    lager:info("stopping test ~p", [TestCase]),
    FakeLNSPid = proplists:get_value(fake_lns, Config),
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

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_gateway() -> {libp2p_crypto:pubkeybin(), pid()}.
start_gateway() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    {ok, WorkerPid} = packet_purchaser_udp_sup:maybe_start_worker(PubKeyBin, #{}),
    {PubKeyBin, WorkerPid}.
