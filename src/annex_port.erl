-module(annex_port).
-behaviour(gen_server).

%% API.
-export([start_link/1]).
-export([call/6]).
-export([cast/4]).
-export([stop/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
  requests = #{},
  queue_length :: integer(),
  port :: port(),
  marshal :: module()
}).

%% API.

-spec start_link([]) -> {ok, pid()}.
start_link(Opts) ->
  gen_server:start_link(?MODULE, [Opts], []).

call(Pid, Module, Function, Arguments, Sender, Ref) ->
  gen_server:cast(Pid, {call, Module, Function, Arguments, Sender, Ref}).

cast(Pid, Module, Function, Arguments) ->
  gen_server:cast(Pid, {cast, Module, Function, Arguments}).

stop(Pid) ->
  gen_server:cast(Pid, stop).

%% gen_server.

init([Opts]) ->
  process_flag(trap_exit, true),
  Port = open_port({spawn, fast_key:get(command, Opts)}, [
    binary,
    nouse_stdio
  ]),
  Marshal = fast_key:get(marshal, Opts),
  QueueLength = fast_key:get(queue_length, Opts, 1000),
  {ok, #state{
    queue_length = QueueLength,
    marshal = Marshal,
    port = Port
  }}.

handle_call(_Request, _From, State) ->
  {reply, ignored, State}.

handle_cast({call, Module, Function, Arguments, Sender, Ref}, State) ->
  Requests = State#state.requests,
  case fast_key:size(Requests) < State#state.queue_length of
    true ->
      MsgID = erlang:phash2({Module, Function, Arguments, Sender, Ref, os:timestamp()}),
      Msg = (State#state.marshal):encode(MsgID, call, Module, Function, Arguments),
      port_command(State#state.port, Msg),
      {noreply, State#state{requests = fast_key:set(MsgID, {Sender, Ref}, Requests)}};
    _ ->
      Sender ! {Ref, {error, toobusy}},
      {noreply, State}
  end;
handle_cast({cast, Module, Function, Arguments}, State) ->
  Requests = State#state.requests,
  case fast_key:size(Requests) < State#state.queue_length of
    true ->
      MsgID = erlang:phash2({Module, Function, Arguments, os:timestamp()}),
      Msg = (State#state.marshal):encode(MsgID, cast, Module, Function, Arguments),
      port_command(State#state.port, Msg),
      {noreply, State};
    _ ->
      error_logger:error_msg("Process too busy ~p:~p(~p)~n", [Module, Function, Arguments]),
      {noreply, State}
  end;
handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast(Msg, State) ->
  io:format("UNHANDLED: ~p~n", [Msg]),
  {noreply, State}.

handle_info({Port, {data, Data}}, State = #state{port = Port}) ->
  Requests = State#state.requests,
  case catch (State#state.marshal):decode(Data) of
    {ok, MsgID, Res} ->
      case fast_key:get(MsgID, Requests) of
        {Sender, Ref} ->
          Sender ! {Ref, Res},
          {noreply, State#state{requests = fast_key:remove(MsgID, Requests)}};
        _ ->
          error_logger:error_msg("Message id not found: ~p~nMessage was ~p~n", [MsgID, Res]),
          {noreply, State}
      end;
    Error ->
      error_logger:error_msg("Unable to decode response ~p~n~p~n", [Data, Error]),
      {noreply, State}
  end;
handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
  {stop, Reason, State};
handle_info(Msg, State) ->
  io:format("UNHANDLED: ~p~n", [Msg]),
  {noreply, State}.

terminate(_Reason, #state{port = Port}) ->
  catch port_close(Port),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
