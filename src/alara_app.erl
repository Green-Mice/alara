%% ============================================================================
%% alara_app - OTP Application Callback
%%
%% Starts the entropy worker pool when alara is loaded as an OTP application.
%% Pool size is read from the application environment (key: pool_size).
%%
%% Configure via sys.config:
%%   [{alara, [{pool_size, 5}]}]
%%
%% Or at runtime before starting:
%%   application:set_env(alara, pool_size, 5),
%%   application:start(alara).
%% ============================================================================

-module(alara_app).
-behaviour(application).

-export([start/2, stop/1]).

%% ---------------------------------------------------------------------------
%% Application callbacks
%% ---------------------------------------------------------------------------

-spec start(application:start_type(), term()) -> supervisor:startlink_ret().
start(_Type, _Args) ->
    PoolSize = application:get_env(alara, pool_size, 3),
    alara_node_sup:start_link(PoolSize).

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
