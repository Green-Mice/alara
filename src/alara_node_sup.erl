-module(alara_node_sup).
-behaviour(supervisor).

%% API
-export([start_link/1, start_node/0, get_nodes/0, generate_random_bools/1, generate_random_int/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(NumNodes) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, NumNodes).

%% Start a new node instance
start_node() ->
    supervisor:start_child(?SERVER, []).

get_nodes() ->
    [Pid || {_Id, Pid, _Type, _Modules} <- supervisor:which_children(?SERVER)].

% Generate N random booleans from all nodes (distributed)
generate_random_bools(N) when is_integer(N), N > 0 ->
    Nodes = get_nodes(),
    case length(Nodes) of
        0 -> {error, no_nodes};
        NumNodes ->
            BitsPerNode = N div NumNodes,
            Remainder = N rem NumNodes,
            
            %% Collect bits from each node
            BaseBits = lists:flatmap(
                fun(Node) -> 
                    [alara_node:get_random(Node) || _ <- lists:seq(1, BitsPerNode)]
                end,
                Nodes
            ),
            
            %% Get remaining bits from first node if needed
            case Remainder of
                0 -> BaseBits;
                R -> BaseBits ++ [alara_node:get_random(hd(Nodes)) || _ <- lists:seq(1, R)]
            end
    end.

%% Generate a random integer using NBits
generate_random_int(NBits) when is_integer(NBits), NBits > 0 ->
    case generate_random_bools(NBits) of
        {error, Reason} -> {error, Reason};
        Bits -> bits_to_integer(Bits)
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init(NumNodes) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 5
    },
    
    ChildSpecs = [
        #{
          id => {alara_node, I},
          start => {alara_node, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [alara_node]
         }
        || I <- lists:seq(1, NumNodes)
    ],
    
    
    {ok, {SupFlags, ChildSpecs}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

bits_to_integer(Bits) ->
    lists:foldl(
        fun(Bit, Acc) ->
            BitValue = case Bit of
                true -> 1;
                false -> 0;
                1 -> 1;
                0 -> 0
            end,
            (Acc bsl 1) bor BitValue
        end,
        0,
        Bits
    ).
