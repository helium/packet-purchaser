-module(pp_integration_behavior).

-callback start_link(Args :: map()) -> {ok, pid()} | ignore | {error, any()}.
-callback get_devices() -> {ok, list(binary())} | {error, any()}.
