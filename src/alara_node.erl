-module(alara_node).
-behaviour(gen_server).

-include("alara.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([get_random/1]).


%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
  gen_server:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
  {ok, #node{
          node_id = self(),
          sources = [],
          neighbors = [],
          trust_level = 0.5,
          is_active = true
         }}.

handle_call({get_random}, _From, State) ->
  {reply, rand:uniform(2) =:= 1, State};
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast({get_random}, State) ->
  {reply, rand:uniform(2) =:=1, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, #node{node_id = _Id}) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================).


get_random(NId) ->
  gen_server:call(NId, {get_random}).

