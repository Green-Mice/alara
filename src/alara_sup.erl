%% ============================================================================
%% alara_sup - Root Supervisor
%%
%% Top-level one_for_one supervisor. Starts alara_cluster_monitor first
%% (so it is available when alara_node_sup workers come online) and stops
%% it last.
%% ============================================================================

-module(alara_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    PoolSize = application:get_env(alara, pool_size, 3),
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 5
    },
    Children = [
        #{
            id       => alara_cluster_monitor,
            start    => {alara_cluster_monitor, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [alara_cluster_monitor]
        },
        #{
            id       => alara_node_sup,
            start    => {alara_node_sup, start_link, [PoolSize]},
            restart  => permanent,
            shutdown => infinity,
            type     => supervisor,
            modules  => [alara_node_sup]
        }
    ],
    {ok, {SupFlags, Children}}.
