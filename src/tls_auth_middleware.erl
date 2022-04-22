-module(tls_auth_middleware).
-behaviour(cowboy_middleware).

-export([execute/2]).

execute(Req, Env) ->
    DerCert = cowboy_req:cert(Req),
    ClientIdentity = tls_utils:get_subject_identity(DerCert),
    Req1 = maps:put('_client_auth', client_auth:new(ClientIdentity), Req),
    {ok, Req1, Env}.
