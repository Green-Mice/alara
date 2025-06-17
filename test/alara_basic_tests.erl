-module(alara_basic_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("alara/include/alara.hrl").

basic_scenario_test() ->
    {ok, NetPid} = alara:create_network(),
    {ok, Node} = alara:create_node(1, 0.9, true),
    {ok, node_added} = alara:add_node(NetPid, Node),
    Bits = [rand:uniform(2) =:= 1 || _ <- lists:seq(1, 32)],
    ok = alara:generate_entropy(NetPid, {1, Bits}),
    timer:sleep(100), % Let the cast complete
    {ok, Network} = gen_server:call(NetPid, get_network_state),
    Pool = Network#distributed_entropy_network.global_entropy_pool,
    ?assertEqual(Bits, lists:sublist(Pool, 32)).

multiple_nodes_entropy_test() ->
    % Create the network
    {ok, NetPid} = alara:create_network(),
    
    % Create multiple nodes with different trust levels
    {ok, Node1} = alara:create_node(1, 0.9, true),
    {ok, Node2} = alara:create_node(2, 0.8, true),
    {ok, Node3} = alara:create_node(3, 0.7, true),
    
    % Add nodes to the network
    {ok, node_added} = alara:add_node(NetPid, Node1),
    {ok, node_added} = alara:add_node(NetPid, Node2),
    {ok, node_added} = alara:add_node(NetPid, Node3),
    
    % Each node contributes entropy
    Bits1 = [rand:uniform(2) =:= 1 || _ <- lists:seq(1, 32)],
    Bits2 = [rand:uniform(2) =:= 1 || _ <- lists:seq(1, 32)],
    Bits3 = [rand:uniform(2) =:= 1 || _ <- lists:seq(1, 32)],
    
    ok = alara:generate_entropy(NetPid, {1, Bits1}),
    ok = alara:generate_entropy(NetPid, {2, Bits2}),
    ok = alara:generate_entropy(NetPid, {3, Bits3}),
    
    timer:sleep(200), % Wait for propagation
    
    % Retrieve the global pool
    {ok, Network} = gen_server:call(NetPid, get_network_state),
    Pool = Network#distributed_entropy_network.global_entropy_pool,
    
    % Generate a random number from the combined pool
    RandomNumber = generate_random_from_pool(Pool, 32),
    
    ?assert(length(Pool) >= 96), % At least 3 * 32 bits
    ?assert(is_integer(RandomNumber)),
    ?assert(RandomNumber >= 0).

weighted_random_generation_test() ->
    {ok, NetPid} = alara:create_network(),
    
    % Nodes with different trust levels and contribution sizes
    Nodes = [
        {1, 0.9, 32}, % ID, Trust, Bits to contribute
        {2, 0.8, 24},
        {3, 0.7, 16},
        {4, 0.6, 8}
    ],
    
    % Add and make each node contribute
    lists:foreach(fun({NodeId, Trust, NumBits}) ->
        {ok, Node} = alara:create_node(NodeId, Trust, true),
        {ok, node_added} = alara:add_node(NetPid, Node),
        
        Bits = [rand:uniform(2) =:= 1 || _ <- lists:seq(1, NumBits)],
        ok = alara:generate_entropy(NetPid, {NodeId, Bits})
    end, Nodes),
    
    timer:sleep(300), % Wait for all entropy to propagate
    
    % Generate multiple random numbers
    {ok, Network} = gen_server:call(NetPid, get_network_state),
    Pool = Network#distributed_entropy_network.global_entropy_pool,
    % Only generate as many randoms as we can with available entropy
    MaxRandoms = length(Pool) div 16, % 16 bits per random
    RandomNumbers = generate_multiple_randoms(Pool, MaxRandoms, 16),
    
    ?assertEqual(MaxRandoms, length(RandomNumbers)),
    ?assert(lists:all(fun(N) -> is_integer(N) andalso N >= 0 end, RandomNumbers)),
    ?assert(length(Pool) >= 80), % At least sum of all contributed bits
    ?assert(MaxRandoms >= 5). % Should be able to generate at least 5 randoms with 80 bits

%% Helper functions for random number generation
generate_random_from_pool(Pool, NumBits) when length(Pool) >= NumBits ->
    SelectedBits = lists:sublist(Pool, NumBits),
    bits_to_integer(SelectedBits);
generate_random_from_pool(_Pool, _NumBits) ->
    error(insufficient_entropy).

generate_multiple_randoms(Pool, Count, BitsPerRandom) ->
    generate_multiple_randoms(Pool, Count, BitsPerRandom, []).

generate_multiple_randoms(_Pool, 0, _BitsPerRandom, Acc) ->
    lists:reverse(Acc);
generate_multiple_randoms(Pool, Count, BitsPerRandom, Acc) when length(Pool) >= BitsPerRandom ->
    Random = generate_random_from_pool(Pool, BitsPerRandom),
    % Use different parts of the pool for each random number
    RemainingPool = lists:nthtail(BitsPerRandom, Pool),
    generate_multiple_randoms(RemainingPool, Count - 1, BitsPerRandom, [Random|Acc]);
generate_multiple_randoms(_Pool, _Count, _BitsPerRandom, Acc) ->
    lists:reverse(Acc). % Return what we have if insufficient entropy

bits_to_integer(Bits) ->
    bits_to_integer(Bits, 0, 0).

bits_to_integer([], _Power, Acc) ->
    round(Acc);
bits_to_integer([Bit|Rest], Power, Acc) ->
    Value = case Bit of
        true -> 1;
        false -> 0;
        1 -> 1;
        0 -> 0
    end,
    bits_to_integer(Rest, Power + 1, Acc + (Value * math:pow(2, Power))).
