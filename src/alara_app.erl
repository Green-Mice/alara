-module(alara_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    alara_sup:start_link().

stop(_State) -> ok.
