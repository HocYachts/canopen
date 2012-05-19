%%%---- BEGIN COPYRIGHT --------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2012, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ----------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Malotte Westman L�nne <malotte@malotte.net>
%%% @copyright (C) 2012, Tony Rogvall
%%% @doc
%%%  Handles CANopen NMT protocol.
%%%
%%% File: co_nmt.erl
%%% Created:  3 May 2012 by Malotte Westman L�nne
%%% @end
%%%-------------------------------------------------------------------
-module(co_nmt).

-include_lib("can/include/can.hrl").
-include("canopen.hrl").
-include("co_app.hrl").
-include("co_debug.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1, 
	 stop/0,
	 slaves/0,
	 subscribe/0,
	 subscribe/1,
	 unsubscribe/0,
	 unsubscribe/1,
	 subscribers/0,
	 alive/0,
	 send_nmt_command/1,
	 send_nmt_command/2,
	 save/0,
	 load/0]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).


%% Test functions
-export([debug/1,
	 add_slave/1,
	 remove_slave/1,
	 dump/0]).

-define(NMT_MASTER, co_nmt_master).
-define(NMT_CONF, "nmt.conf").

-record(ctx, 
	{
	  node_pid,           %% Pid of co_node
	  supervision = none, %% Type of supervision
	  subscribers = [],   %% Receives error notifications
	  nmt_table           %% Table of NMT slaves
	 }).

-record(nmt_slave,
	{
	  id,                  %% node id (key)
	  guard_time = 0,
	  life_factor = 0,
	  guard_timer,
	  life_timer,
	  com_status = ok,
	  node_state=?PreOperational,
	  toggle = 0           %% Expected next toggle
	 }).

-type nmt_command()::
	start |          %% enter operational ??
	stop |
	enter_pre_op |
	reset_node |
	reset_com.
	
	


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server.
%% @end
%%--------------------------------------------------------------------
-spec start_link(list(tuple())) -> 
			{ok, Pid::pid()} | ignore | {error, Error::term()}.

start_link(Args) ->
    error_logger:info_msg("~p: start_link: args = ~p\n", [?MODULE, Args]),
    F =	case proplists:get_value(linked,Args,true) of
	    true -> start_link;
	    false -> start
	end,
    
    case whereis(?NMT_MASTER) of
	Pid when is_pid(Pid) ->
	    {error, already_started};
	undefined ->
	    gen_server:F({local, ?NMT_MASTER}, ?MODULE, Args, [])
    end.


%%--------------------------------------------------------------------
%% @doc
%% Stops the server.
%%
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok | {error, Reason::atom()}.
				  
stop() ->
    case whereis(?NMT_MASTER) of
	Pid when is_pid(Pid) ->
	    gen_server:call(?NMT_MASTER, stop);
	undefined ->
	    ok
    end.


%%--------------------------------------------------------------------
%% @doc
%% Returns a list of supervised slaves
%%
%% @end
%%--------------------------------------------------------------------
-spec slaves() -> list({SlaveId::node_id(), 
			State::integer(), 
			ComStatus::waiting | lost | ok}) | 
		  {error, Reason::atom()}.
				  
slaves() ->
    gen_server:call(?NMT_MASTER, slaves).
  


%%--------------------------------------------------------------------
%% @doc
%% Subscribe to error notifications.
%% @end
%%--------------------------------------------------------------------
-spec subscribe() -> ok.

subscribe() ->
    gen_server:call(?NMT_MASTER, {subscribe, self()}).

%%--------------------------------------------------------------------
%% @doc
%% Subscribe to error notifications.
%% @end
%%--------------------------------------------------------------------
-spec subscribe(Pid::pid()) -> ok.

subscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?NMT_MASTER, {subscribe, Pid}).

%%--------------------------------------------------------------------
%% @doc
%% Unsubscribe to error notifications.
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe() -> ok.

unsubscribe() ->
    gen_server:call(?NMT_MASTER, {unsubscribe, self()}).

%%--------------------------------------------------------------------
%% @doc
%% Unsubscribe to error notifications.
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe(Pid::pid()) -> ok.

unsubscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?NMT_MASTER, {unsubscribe, Pid}).

%%--------------------------------------------------------------------
%% @doc
%% Returns all subscribers.
%% @end
%%--------------------------------------------------------------------
-spec subscribers() -> ok.

subscribers() ->
    gen_server:call(?NMT_MASTER, subscribers).

%%--------------------------------------------------------------------
%% @doc
%% Checks if the co_proc still is alive.
%% @end
%%--------------------------------------------------------------------
-spec alive() -> true | false.

alive() ->
    case whereis(?NMT_MASTER) of
	undefined -> false;
	_PI -> true
    end.

%%--------------------------------------------------------------------
%% @doc
%% Sends nmt command to all slaves.
%% @end
%%--------------------------------------------------------------------
-spec send_nmt_command(NmtCommand::nmt_command()) ->
    ok | {error, Reason::term()}.

send_nmt_command(NmtCommand)
  when NmtCommand == start;
       NmtCommand == stop;
       NmtCommand == enter_pre_op;
       NmtCommand == reset_node;
       NmtCommand == reset_com ->
    gen_server:call(?NMT_MASTER, {send_all, NmtCommand});
send_nmt_command(_Nmt) ->
    {error, unknown_nmt_command}.


%%--------------------------------------------------------------------
%% @doc
%% Sends nmt command to slave.
%% @end
%%--------------------------------------------------------------------
-spec send_nmt_command(SlaveId::node_id(),
		       NmtCommand::nmt_command()) ->
    ok | {error, Reason::term()}.

send_nmt_command(SlaveId, NmtCommand)
  when NmtCommand == start;
       NmtCommand == stop;
       NmtCommand == enter_pre_op;
       NmtCommand == reset_node;
       NmtCommand == reset_com ->
    gen_server:call(?NMT_MASTER, {send_slave, SlaveId, NmtCommand}).

%%--------------------------------------------------------------------
%% @doc
%% Adds slave to supervise.
%% @end
%%--------------------------------------------------------------------
-spec add_slave(SlaveId::node_id()) ->
    ok | {error, Reason::term()}.

add_slave(SlaveId = {_Flag, NodeId}) when is_integer(NodeId) ->
    gen_server:call(?NMT_MASTER, {add_slave, SlaveId}).

%%--------------------------------------------------------------------
%% @doc
%% Remove slave from supervision.
%% @end
%%--------------------------------------------------------------------
-spec remove_slave(SlaveId::node_id()) ->
    ok | {error, Reason::term()}.

remove_slave(SlaveId = {_Flag, NodeId}) when is_integer(NodeId) ->
    gen_server:call(?NMT_MASTER, {remove_slave, SlaveId}).

%%--------------------------------------------------------------------
%% @doc
%% Saves nmt configuration (slaves to supervise).
%% @end
%%--------------------------------------------------------------------
-spec save() -> ok | {error, Reason::term()}.

save() ->
    gen_server:call(?NMT_MASTER, save).


%%--------------------------------------------------------------------
%% @doc
%% Restores saved nmt configuration (slaves to supervise).
%% @end
%%--------------------------------------------------------------------
-spec load() -> ok | {error, Reason::term()}.

load() ->
    gen_server:call(?NMT_MASTER, load).


%%--------------------------------------------------------------------
%% @doc
%% Adjust debug flag.
%% @end
%%--------------------------------------------------------------------
-spec debug(TrueOrFalse::boolean()) -> ok.

debug(TrueOrFalse) when is_boolean(TrueOrFalse) ->
    gen_server:call(?NMT_MASTER, {debug, TrueOrFalse}).

%%--------------------------------------------------------------------
%% @doc
%% Dump data.
%% @end
%%--------------------------------------------------------------------
-spec dump() -> ok.

dump()  ->
    gen_server:call(?NMT_MASTER,dump).

	
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
-spec init(list(term())) -> {ok, Ctx::#ctx{}}.

init(Args) ->
    error_logger:info_msg("~p: init: args = ~p, pid = ~p\n", 
			  [?MODULE, Args, self()]),

    %% Trace output enable/disable
    put(dbg, proplists:get_value(debug,Args,false)), 

    case proplists:get_value(node_pid, Args) of
	NodePid when is_pid(NodePid) ->
	    %% Manager needed
	    co_mgr:start([{debug, get(dbg)}]),
	    Supervision = proplists:get_value(supervision, Args, none),
	    NMT = ets:new(co_nmt_table, [{keypos,#nmt_slave.id},
					 protected, named_table, ordered_set]),
	    Ctx = #ctx {node_pid = NodePid, 
			supervision = Supervision,
			nmt_table = NMT},
	    %% Load conf if it exists
	    load_conf(Ctx),
	    {ok, Ctx};
	_NotPid ->
	    {error, no_co_node}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-type call_request()::
	{send_all, Cmd::integer()} |
	{send_slave, SlaveId::node_id(), Cmd::integer()} |
	{add_slave, SlaveId::node_id()} |
	{remove_slave, SlaveId::node_id()} |
	save |
	load |
	{debug, TrueOrFalse::boolean()} |
	stop.

-spec handle_call(Request::call_request(),
		  From::{pid(), term()}, Ctx::#ctx{}) ->
			 {reply, Reply::term(), Ctx::#ctx{}} |
			 {stop, Reason::term(), Reply::term(), Ctx::#ctx{}}.

handle_call(slaves, _From, Ctx=#ctx {nmt_table = NmtTable}) ->
    ?dbg(nmt, "handle_call: slaves", []),
    SlaveList = 
	ets:select(NmtTable, [{#nmt_slave{id='$1', 
					  node_state = '$2', 
					  com_status='$3', 
					  _='_'},
			       [],[{{'$1','$2','$3'}}]}]),
    {reply, SlaveList, Ctx};
handle_call({send_slave, SlaveId = {_Flag, _NodeId}, Cmd}, _From, 
	    Ctx=#ctx {nmt_table = NmtTable}) ->
    ?dbg(nmt, "handle_call: send_slave {~p,~.16#} ~p", [_Flag, _NodeId, Cmd]),
    case ets:lookup(NmtTable, SlaveId) of
	[Slave] -> 
	    {reply, send_to_slave(Slave, Cmd, Ctx), Ctx};
	[] -> 
	    {reply, {error, unknown_slave}, Ctx}
    end;

handle_call({send_all, Cmd}, _From, Ctx) ->
    ?dbg(nmt, "handle_call: send_all ~p", [Cmd]),
    {reply, send_all(Cmd, Ctx), Ctx};

handle_call({subscribe, Pid}, _From, Ctx=#ctx {subscribers = SubList}) ->
    ?dbg(nmt, "handle_call: subscribe ~p", [Pid]),
    case lists:keymember(Pid, 1, SubList) of
	true ->
	    {reply, ok, Ctx};
	false ->
	    Mon = erlang:monitor(process, Pid),
	    {reply, ok, Ctx#ctx {subscribers = [{Pid, Mon} | SubList]}}
    end;

handle_call({unsubscribe, Pid}, _From, Ctx=#ctx {subscribers = SubList}) ->
    ?dbg(nmt, "handle_call: unsubscribe ~p", [Pid]),
    {reply, ok, Ctx#ctx {subscribers = lists:keydelete(Pid,1,SubList)}};

handle_call(subscribers, _From, Ctx=#ctx {subscribers = SubList}) ->
    ?dbg(nmt, "handle_call: subscribers", []),
    {reply, {ok, [Sub || {Sub, _Mon} <- SubList]}, Ctx};

handle_call({add_slave, SlaveId = {_Flag, _NodeId}}, _From, 
	    Ctx=#ctx {nmt_table = NmtTable}) ->
    ?dbg(nmt, "handle_call: add_slave {~p,~.16#}", [_Flag, _NodeId]),
    case ets:lookup(NmtTable, SlaveId) of
	[_Slave] -> ok; %% already handled
	[] -> add_slave(SlaveId, Ctx)
    end,
    {reply, ok, Ctx};

handle_call({remove_slave, SlaveId = {_Flag, _NodeId}}, _From, 
	    Ctx=#ctx {nmt_table = NmtTable}) ->
    ?dbg(nmt, "handle_call: remove_slave {~p,~.16#}", [_Flag, _NodeId]),
    case ets:lookup(NmtTable, SlaveId) of
	[] -> ok; %% not handled
	[Slave] -> remove_slave(Slave, Ctx)
    end,
    {reply, ok, Ctx};

handle_call(save, _From, Ctx=#ctx {nmt_table = NmtTable}) ->
    File = filename:join(code:priv_dir(canopen), ?NMT_CONF),
    ?dbg(nmt, "handle_call: save nmt configuration to ~p", [File]),
    case file:open(File, [write]) of
	{ok, Fd} ->
	    Tab = ets:tab2list(NmtTable),
	    io:format(Fd,"~p.\n",[Tab]),
	    file:close(Fd),
	    {reply, ok, Ctx};
	Error ->
	    {reply, Error, Ctx}
    end;
	
handle_call(load, _From, Ctx) ->
    ?dbg(nmt, "handle_call: load nmt configuration.", []),
    Reply = load_conf(Ctx),
    {reply, Reply, Ctx};

handle_call({debug, TrueOrFalse}, _From, Ctx) ->
    put(dbg, TrueOrFalse),
    {reply, ok, Ctx};

handle_call(dump, _From, Ctx) ->
    io:format("---- NMT TABLE ----\n"),
    ets:foldl(
      fun(E=#nmt_slave {id = {Flag, NodeId}},_) ->
	      io:format("  ID: {~p,~.16#}\n", 
			[Flag, NodeId]),
	      io:format("     STATE: ~s\n", 
			[co_format:state(E#nmt_slave.node_state)]),
	      io:format("COM STATUS: ~p\n", 
			[E#nmt_slave.com_status])
      end, ok, Ctx#ctx.nmt_table),
   {reply, ok, Ctx};

handle_call(stop, _From, Ctx) ->
    {stop, normal, ok, Ctx};

handle_call(_Call, _From, Ctx) ->
    ?dbg(nmt, "handle_call: unknown call ~p, ignored", [_Call]),
    {reply, {error, bad_call}, Ctx}.
    

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-type msg()::
	{node_guard_reply, SlaveId::node_id(), Frame::#can_frame{}} | 
	{supervision, node_guard | heartbeat | none} | 
	term().

-spec handle_cast(Msg::msg(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}}.

handle_cast({node_guard_reply, SlaveId, Frame}, Ctx) 
  when Frame#can_frame.len >= 1 ->
    ?dbg(nmt, "handle_cast: node_guard_reply ~w", [Frame]),
    case Frame#can_frame.data of
	<<Toggle:1, State:7, _/binary>> ->
	    handle_node_guard(SlaveId, State, Toggle, Ctx);
	_ ->
	    do_nothing
    end,
    {noreply, Ctx};

handle_cast({supervision, Supervision}, Ctx=#ctx {supervision = Supervision}) ->
    ?dbg(?NAME," handle_cast: supervision ~p, no change.", [Supervision]),
    {noreply, Ctx};
handle_cast({supervision, heartbeat}, Ctx) ->
    ?dbg(?NAME," handle_cast: heartbeat not implemented, setting to none.", []),
    handle_cast({supervison, none}, Ctx);
handle_cast({supervision, New}, Ctx=#ctx {supervision = Old}) ->
    ?dbg(?NAME," handle_cast: supervision ~p -> ~p.", [Old, New]),
    %% Activate/deactivate .. or handle in co_node ??
    case {New, Old} of
	{node_guard, _Other} -> activate_node_guard(Ctx);
	{_Other, node_guard} -> deactivate_node_guard(Ctx)
    end,
    {noreply, Ctx#ctx {supervision = New}};
handle_cast(_Msg, Ctx) ->
    ?dbg(?NAME," handle_cast: Unknown message = ~p, ignored. ", [_Msg]),
    {noreply, Ctx}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages.
%% Handles 'DOWN' messages for monitored processes.
%% @end
%%--------------------------------------------------------------------
-type info()::
	{do_node_guard, SlaveId::integer()} |
	{node_guard_timeout, SlaveId::integer()} | 
	term().


-spec handle_info(Info::info(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}}.

handle_info({do_node_guard, SlaveId = {_Flag, _NodeId}}, 
	    Ctx=#ctx {nmt_table = NmtTable, node_pid = NodePid}) ->
    ?dbg(nmt, "handle_info: do_node_guard for {~p,~.16#}", [_Flag, _NodeId]),
    case ets:lookup(NmtTable, SlaveId) of
	[] -> 
	    ?dbg(nmt, "handle_info: do_node_guard, slave not found!", []),
	    ok;
	[Slave] -> 
	    send_node_guard(SlaveId, NodePid),
	    TRef = erlang:send_after(Slave#nmt_slave.guard_time, self(), 
				     {do_node_guard, SlaveId}),
	    NewComStatus = if Slave#nmt_slave.com_status == lost -> lost;
			      true -> waiting
			   end,
	    ets:insert(NmtTable, Slave#nmt_slave {com_status = NewComStatus,
						  guard_timer = TRef})
    end,
    {noreply, Ctx};

handle_info({node_guard_timeout, SlaveId = {_Flag, _NodeId}}, 
	    Ctx=#ctx {nmt_table = NmtTable}) ->
    ?dbg(nmt, "handle_info: node_guard timeout received for {~p,~.16#}", 
	 [_Flag, _NodeId]),
    case ets:lookup(NmtTable, SlaveId) of
	[] -> 
	    ?dbg(nmt, "handle_info: node_guard_timeout, slave not found!", []),
	    ok;
	[Slave] -> 
	    error_logger:error_msg("Node guard timeout, check NMT slave {~p,~.16#}\n", 
			   [_Flag, _NodeId]),
	    inform_subscribers({lost_contact, SlaveId}, Ctx),
	    ets:insert(NmtTable, Slave#nmt_slave {com_status = lost})
    end,
    %% Start again ??
    {noreply, Ctx};

handle_info({'DOWN',_Ref,process,Pid,_Reason}, 
	    Ctx=#ctx {subscribers = SubList}) ->
    ?dbg(nmt, "handle_info: DOWN for subscriber process ~p received, "
	 "reason ~p", [Pid, _Reason]),
    {noreply, Ctx#ctx {subscribers = lists:keydelete(Pid,1,SubList)}};

handle_info(_Info, Ctx) ->
    ?dbg(?NAME," handle_info: Unknown Info ~p, ignored.\n", [_Info]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason::term(), Ctx::#ctx{}) -> 
		       no_return().

terminate(_Reason, _Ctx) ->
    ?dbg(node, "terminate: reason ~p, exiting", [_Reason]),
    co_mgr:stop(),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process ctx when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn::term(), Ctx::#ctx{}, Extra::term()) -> 
			 {ok, NewCtx::#ctx{}}.

code_change(_OldVsn, Ctx, _Extra) ->
    {ok, Ctx}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

load_conf(_Ctx=#ctx {nmt_table = NmtTable}) ->
    File = filename:join(code:priv_dir(canopen), ?NMT_CONF),
    ?dbg(nmt, "load_conf: load nmt configuration from ~p", [File]),
    case filelib:is_regular(File) of
	true ->
	    case file:consult(File) of
		{ok, [List]} ->
		    ?dbg(nmt, "handle_call: loading list ~p", [List]),
		    try ets:insert(NmtTable, List) of
			true -> ok
		    catch
			error:Reason -> {error, Reason}
		    end;
		Error ->
		    Error
	    end;
	false ->
	    {error, no_nmt_conf_exists}
    end.

add_slave(SlaveId = {_Flag, _NodeId}, 
	  Ctx=#ctx {supervision = Supervision, nmt_table = NmtTable}) ->
    ?dbg(nmt, "add_slave: {~p, ~.16#}", [_Flag, _NodeId]),
    Slave = #nmt_slave {id = SlaveId},
    ets:insert(NmtTable, Slave),
    case Supervision of
	none ->
	    ?dbg(nmt, "add_slave: no supervision", []),
	    ok;
	node_guard ->
	    activate_node_guard(Slave, Ctx);
	heartbeat ->
	    %% To be implemented 
	    ?dbg(nmt, "add_slave: heartbeat not implemented yet", []),
	    ok
    end,
    send_to_slave(Slave, start, Ctx).
    

activate_node_guard(Slave=#nmt_slave {id = SlaveId}, 
		    Ctx=#ctx {nmt_table = NmtTable}) ->
    ?dbg(nmt, "activate_node_guard: slave ~p.", [SlaveId]),
    %% get node guard time and life factor
    {GuardTime, LifeFactor} = slave_guard_time(SlaveId),
    case GuardTime of
	undefined ->
	    ?dbg(nmt, "activate_node_guard: slave not reachable", []),
	    error_logger:error_msg(
	      "New slave ~p guard time could not be fetched. "
	      "No supervision possible.\n", [SlaveId]),
	    inform_subscribers({slave_not_supervisable, SlaveId}, Ctx),
	    ets:insert(NmtTable, Slave#nmt_slave {com_status = lost}); %% ???
	0 -> 
	    ?dbg(nmt, "activate_node_guard: guard time = 0, no node guarding", []);
	_T ->
	    ?dbg(nmt, "activate_node_guard: node guarding, ~p * ~p", 
		 [GuardTime, LifeFactor]),
	    NewSlave = Slave#nmt_slave {guard_time = GuardTime,
					life_factor = LifeFactor},
	    GTimer = start_guard_timer(NewSlave),
	    LTimer = start_life_timer(NewSlave),
	    ets:insert(NmtTable, NewSlave#nmt_slave {guard_timer = GTimer,
						     life_timer = LTimer,
						     com_status = ok})
    end.

slave_guard_time(SlaveId) ->
    case co_mgr:fetch(SlaveId, ?IX_GUARD_TIME, segment, 
		      {value, ?UNSIGNED16}) of
	    {ok, GuardTime} ->
	    case co_mgr:fetch(SlaveId, ?IX_LIFE_TIME_FACTOR, segment, 
			      {value, ?UNSIGNED8}) of
		
		{ok, LifeFactor} ->
		    {GuardTime, LifeFactor};
		{error, _Error} ->
		    ?dbg(nmt, "slave_guard_time: fetch life factor failed, reason ~p", 
			 [_Error]),
		    {undefined, undefined} 
	    end;
	_Error ->
	    ?dbg(nmt, "slave_guard_time: fetch guard time failed, reason ~p", 
		 [_Error]),
	    {undefined, undefined} 
    end.


remove_slave(Slave=#nmt_slave {id = SlaveId = {_Flag, _NodeId}},
	     Ctx=#ctx {supervision = Supervision, nmt_table = NmtTable}) ->
    ?dbg(nmt, "remove_slave: {~p, ~.16#}", [_Flag, _NodeId]),
    case Supervision of 
	none ->
	    ok;
	node_guard ->
	    deactivate_node_guard(Slave, Ctx);
	heartbeat ->
	    %% To be implemented
	    ok
    end,
    ets:delete(NmtTable,SlaveId).

deactivate_node_guard(Slave=#nmt_slave {id = SlaveId}, 
		      _Ctx=#ctx {nmt_table = NmtTable}) ->
    ?dbg(nmt, "deactivate_node_guard: slave ~p.", [SlaveId]),
    cancel_life_timer(Slave),
    cancel_guard_timer(Slave),
    ets:insert(NmtTable, Slave#nmt_slave {guard_timer = undefined, 
					  life_timer = undefined}).

send_to_slave(Slave=#nmt_slave {id = SlaveId}, Cmd, _Ctx=#ctx {nmt_table = NmtTable}) ->
    case send_nmt(SlaveId, co_lib:encode_nmt_command(Cmd)) of
	ok ->
	    update_slave_state(Slave, Cmd, NmtTable),
	    ok;
	 Error ->
	    Error
    end.

send_all(Cmd, Ctx=#ctx {nmt_table = NmtTable}) ->
    ets:foldl(fun(Slave,[]) ->
		      send_to_slave(Slave, Cmd, Ctx),
		      []
	      end, [], NmtTable).

update_slave_state(Slave, start, NmtTable) ->
    ets:insert(NmtTable, Slave#nmt_slave {node_state = ?Operational});
update_slave_state(Slave, stop, NmtTable) ->
    ets:insert(NmtTable, Slave#nmt_slave {node_state = ?Stopped});
update_slave_state(Slave, enter_pre_op, NmtTable) ->
    ets:insert(NmtTable, Slave#nmt_slave {node_state = ?PreOperational});
update_slave_state(Slave, reset, NmtTable) ->
    ets:insert(NmtTable, Slave#nmt_slave {node_state = ?PreOperational});
update_slave_state(Slave, reset_com, NmtTable) ->
    ets:insert(NmtTable, Slave#nmt_slave {node_state = ?PreOperational}).

inform_subscribers(Msg, _Ctx=#ctx {subscribers = SubList}) ->
    lists:foreach(fun({Sub, _Mon}) -> Sub ! Msg  end,  SubList).


handle_node_guard(SlaveId = {Flag, NodeId}, State, Toggle, 
		  Ctx=#ctx {supervision = Supervision, nmt_table = NmtTable}) ->
    ?dbg(nmt, "handle_node_guard: node {~p, ~.16#}, state ~p, toggle ~p", 
	 [Flag, NodeId, State, Toggle]),
    case ets:lookup(NmtTable, SlaveId) of
	[] -> 
	    %% First message
	    ?dbg(nmt, "handle_node_guard: new node, creating entry", []),
	    if State =/= ?Initialisation -> %% bootup
		    error_logger:error_msg(
		      "Slave ~p has unexpected state ~s\n",
		      [SlaveId, co_format:state(State)]),	    
		    inform_subscribers({wrong_slave_state, SlaveId, State}, Ctx);
	       true -> ok
	    end,
	    add_slave(SlaveId, Ctx);
	[Slave] when Supervision == node_guard -> 
	    if Slave#nmt_slave.toggle == Toggle andalso
	       Slave#nmt_slave.node_state == State ->
		    node_guard_ok(Slave, Toggle, State, NmtTable);

	       Slave#nmt_slave.node_state =/= State ->
		    %% This can be because it is a node with both
		    %% short and extended node id and co_nmt only knows
		    %% about state change of short node id.
		    ?dbg(nmt, "handle_node_guard: expected state ~p", 
			 [Slave#nmt_slave.node_state]),
		    %% Send error ??
		    error_logger:warning_msg(
		      "Node {~p, ~.16#} answered node guard "
		      "with unexpected state ~p, updating.\n", 
					   [Flag, NodeId, State]),
		    node_guard_ok(Slave, Toggle, State, NmtTable);

	       Slave#nmt_slave.toggle =/= Toggle ->
		    ?dbg(nmt, "handle_node_guard: expected toggle ~p", 
			 [Slave#nmt_slave.toggle]),
		    %% Send error ??
		    error_logger:error_msg(
		      "Node {~p, ~.16#} answered node guard "
		      "with wrong toggle, ignored.\n", 
					   [Flag, NodeId])
	    end;
	[_Slave] when Supervision == none -> 
	    ?dbg(nmt, "handle_node_guard: no supervision", []),
	    ok
    end.

node_guard_ok(Slave, Toggle, State, NmtTable) ->
    %% Restart life timer
    cancel_life_timer(Slave),
    NewTimer = start_life_timer(Slave),
    ets:insert(NmtTable, Slave#nmt_slave {toggle = 1 - Toggle,
					  node_state = State,
					  life_timer = NewTimer,
					  com_status = ok}).

activate_node_guard(Ctx=#ctx {nmt_table = NmtTable}) ->
    ?dbg(nmt, "activate_node_guard: ", []),
    ets:foldl(fun(Slave=#nmt_slave {id = _SlaveId},[]) ->
		      ?dbg(nmt, "activate_node_guard: slave ~p.", [_SlaveId]),
		      activate_node_guard(Slave, Ctx),
		      []
	      end, [], NmtTable).
    
deactivate_node_guard(Ctx=#ctx {nmt_table = NmtTable}) ->
    ets:foldl(fun(Slave,[]) ->
		      deactivate_node_guard(Slave, Ctx),
		      []
	      end, [], NmtTable).

start_life_timer(_Slave=#nmt_slave {guard_time = GT, life_factor = LF, id = Id}) ->
    case GT * LF of
	0 -> 
	    undefined; %% No node guarding
	NLT ->
	    erlang:send_after(NLT, self(), {node_guard_timeout, Id})
    end.

cancel_life_timer(_Slave=#nmt_slave {life_timer = undefined}) ->
    do_nothing;
cancel_life_timer(_Slave=#nmt_slave {life_timer = Timer}) ->
    erlang:cancel_timer(Timer).

start_guard_timer(_Slave=#nmt_slave {guard_time = 0}) ->
    undefined; %% No node guarding
start_guard_timer(_Slave=#nmt_slave {guard_time = GT, id = Id}) ->
    erlang:send_after(GT, self(), {do_node_guard, Id}).


cancel_guard_timer(_Slave=#nmt_slave {guard_timer = undefined}) ->
    do_nothing;
cancel_guard_timer(_Slave=#nmt_slave {guard_timer = Timer}) ->
    erlang:cancel_timer(Timer).


send_nmt(_SlaveId = {xnodeid, _NodeId}, _Cmd) ->
     ?dbg(nmt, "send_nmt: can not send ~p to xnodeid slave ~.16#", 
	  [_Cmd, _NodeId]),
       {error, xnodeid_not_possible};
send_nmt(_SlaveId = {Flag, NodeId}, Cmd) ->
    ?dbg(nmt, "send_nmt: slave {~p, ~.16#}, ~p", [Flag, NodeId, Cmd]),
    can:send(#can_frame { id = ?COBID_TO_CANID(?NMT_ID),
			  len = 2,
			  data = <<Cmd:8, NodeId:8>>}).

send_node_guard(_SlaveId = {Flag, NodeId}, NodePid) ->
    ?dbg(nmt, "send_node_guard: slave {~p, ~.16#}", [Flag, NodeId]),
    Id = 
	if Flag == xnodeid ->
		?COBID_TO_CANID(?XCOB_ID(?NODE_GUARD,NodeId)) 
		    bor ?CAN_RTR_FLAG;
	   Flag == nodeid ->
		?COBID_TO_CANID(?COB_ID(?NODE_GUARD,NodeId)) 
		    bor ?CAN_RTR_FLAG
	end,
    can:send_from(NodePid, #can_frame { id = Id, len = 0, data = <<>>}).



    


