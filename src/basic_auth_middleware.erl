-module(basic_auth_middleware).
-behaviour(cowboy_middleware).

-export([execute/2]).

execute(Req, Env) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, Username, Password} ->
            do_basic_auth(Username, Password, Req, Env);
        _ ->
            Req1 = cowboy_req:reply(401, Req),
            {stop, Req1, Env}
    end.

do_basic_auth(Username, Password, Req, Env) ->
    case {Username, Password} of
        {User, <<"ValidPassword">>} ->
            Req1 = maps:put('_client_auth', client_auth:new(User), Req),
            {ok, Req1, Env};
        _ ->
            %% Req1 = maps.put('_client_auth', client_auth:new(), Req),
            Req1 = cowboy_req:reply(401, Req),
            {stop, Req1, Env}
    end.
