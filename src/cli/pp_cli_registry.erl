-module(pp_cli_registry).

-define(CLI_MODULES, [
    pp_cli_info,
    pp_cli_config
]).

-export([register_cli/0]).

register_cli() ->
    clique:register(?CLI_MODULES).
