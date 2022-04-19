%%%-------------------------------------------------------------------
%% @doc pp_cli_config
%% @end
%%%-------------------------------------------------------------------
-module(pp_cli_config).

-behavior(clique_handler).

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [config_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [config_cmd()]
    ).

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

config_usage() ->
    [
        ["config"],
        [
            "\n\n",
            "config ls      - list\n",
            "config pull    - pull config from console\n"
        ]
    ].

config_cmd() ->
    [
        [["config", "ls"], [], [], fun config_list/3],
        [["config", "pull"], [], [], fun config_pull/3]
    ].

config_list(["config", "ls"], [], []) ->
    {ok, #{routing := Routing}} = pp_config:get_config(),
    Rows = lists:map(
        fun(DevAddr) ->
            [
                {"  Net ID  ",
                    string:right(erlang:integer_to_list(pp_config:net_id(DevAddr), 16), 6, $0)},
                {"   Name   ", pp_config:name(DevAddr)},
                {"  Multi Buy  ", pp_config:multi_buy(DevAddr)},
                {"  Is Buying  ", pp_config:buying_active(DevAddr)}
            ]
        end,
        lists:sort(fun(A, B) -> pp_config:name(A) < pp_config:name(B) end, Routing)
    ),
    c_table(Rows);
config_list(_, _, _) ->
    usage.

config_pull(["config", "pull"], [], []) ->
    ok = pp_console_ws_worker:send_get_config(),
    c_text("config pulled");
config_pull(_, _, _) ->
    usage.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].
