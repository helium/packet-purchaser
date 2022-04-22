-module(hello_handler).

-behaviour(cowboy_handler).

-export([init/2]).

init(Req, State) ->
    handle(client_auth:is_authenticated(Req), Req, State).

handle(_IsAuthenticated = true, Req0, State) ->
    lager:info("Request is authenticated.  Client is ~p.~n", [client_auth:client_id(Req0)]),
    Req1 = cowboy_req:reply(
             200,
             #{<<"content-type">> => <<"application/json">>},
             jsx:encode(#{
                          <<"success">> => true,
                          <<"message">> => <<"Hello!  You were authenticated.">>
                         }),
             Req0
            ),
    {ok, Req1, State}.
