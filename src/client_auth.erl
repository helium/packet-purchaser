-module(client_auth).

-export([
    new/0,
    new/1,
    is_authenticated/1,
    client_id/1
]).

new() ->
    #{
        client_id => undefined,
        is_authenticated => false
    }.

new(ClientId) ->
    #{
        client_id => ClientId,
        is_authenticated => true
    }.

is_authenticated(#{is_authenticated := A}) -> A;
is_authenticated(#{'_client_auth' := Auth}) -> is_authenticated(Auth).

client_id(#{client_id := ClientId}) -> ClientId;
client_id(#{'_client_auth' := Auth}) -> client_id(Auth).
