%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, Karl Anderson
%%% @doc
%%% User auth module
%%%
%%%
%%% @end
%%% Created : 15 Jan 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(user_auth).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("../../include/crossbar.hrl").
-include_lib("webmachine/include/webmachine.hrl").

-define(SERVER, ?MODULE).

-define(TOKEN_DB, <<"token_auth">>).

-define(VIEW_FILE, <<"views/user_auth.json">>).
-define(MD5_LIST, <<"user_auth/creds_by_md5">>).
-define(SHA1_LIST, <<"user_auth/creds_by_sha">>).

-define(AGG_DB, <<"user_auth">>).
-define(AGG_FILTER, <<"users/export">>).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, ok, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({binding_fired, Pid, <<"v1_resource.authorize">>, {RD, #cb_context{req_nouns=[{<<"user_auth">>,[]}]}=Context}}, State) ->
    Pid ! {binding_result, true, {RD, Context}},
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.authenticate">>, {RD, #cb_context{req_nouns=[{<<"user_auth">>,[]}]}=Context}}, State) ->
    Pid ! {binding_result, true, {RD, Context}},
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.allowed_methods.user_auth">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = allowed_methods(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.resource_exists.user_auth">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = resource_exists(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.user_auth">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                crossbar_util:binding_heartbeat(Pid),
                Pid ! {binding_result, true, [RD, validate(Params, Context), Params]}
	 end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.put.user_auth">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                crossbar_util:binding_heartbeat(Pid),
                Pid ! {binding_result, true, [RD, create_token(RD, Context), Params]}
	 end),
    {noreply, State};

handle_info({binding_fired, Pid, _, Payload}, State) ->
    Pid ! {binding_result, false, Payload},
    {noreply, State};

handle_info(timeout, State) ->
    bind_to_crossbar(),
    couch_mgr:db_create(?TOKEN_DB),
    couch_mgr:db_create(?AGG_DB),
    case couch_mgr:update_doc_from_file(?AGG_DB, crossbar, ?VIEW_FILE) of
        {error, _} ->
            couch_mgr:load_doc_from_file(?AGG_DB, crossbar, ?VIEW_FILE);
        {ok, _} -> ok
    end,
    {noreply, State};

handle_info(_, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec(bind_to_crossbar/0 :: () -> no_return()).
bind_to_crossbar() ->
    _ = crossbar_bindings:bind(<<"v1_resource.authenticate">>),
    _ = crossbar_bindings:bind(<<"v1_resource.authorize">>),
    _ = crossbar_bindings:bind(<<"v1_resource.allowed_methods.user_auth">>),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.user_auth">>),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.user_auth">>),
    crossbar_bindings:bind(<<"v1_resource.execute.#.user_auth">>).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec(allowed_methods/1 :: (Paths :: list()) -> tuple(boolean(), http_methods())).
allowed_methods([]) ->
    {true, ['PUT']};
allowed_methods(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec(resource_exists/1 :: (Paths :: list()) -> tuple(boolean(), [])).
resource_exists([]) ->
    {true, []};
resource_exists(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec(validate/2 :: (Params :: list(), Context :: #cb_context{}) -> #cb_context{}).
validate([], #cb_context{req_data=JObj, req_verb = <<"put">>}=Context) ->
    authorize_user(Context, 
                   whapps_json:get_value(<<"credentials">>, JObj), 
                   whapps_json:get_value(<<"method">>, JObj, <<"md5">>)
                  );
validate(_, Context) ->
    crossbar_util:response_faulty_request(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the credentials are valid based on the
%% provided hash method
%%
%% Failure here returns 401
%% @end
%%--------------------------------------------------------------------
-spec(authorize_user/3 :: (Context :: #cb_context{}, Credentials :: binary(), Method :: binary()) -> #cb_context{}).
authorize_user(Context, Credentials, _) when not is_binary(Credentials) ->
    crossbar_util:response(error, <<"invalid credentials">>, 401, Context);
authorize_user(Context, <<"">>, _) ->
    crossbar_util:response(error, <<"invalid credentials">>, 401, Context);
authorize_user(Context, Credentials, <<"md5">>) ->
    case crossbar_doc:load_view(?MD5_LIST, [{<<"key">>, Credentials}], Context#cb_context{db_name=?AGG_DB}) of
        #cb_context{resp_status=success, doc=[JObj]} when JObj =/= []->
            Context#cb_context{resp_status=success, doc=JObj};
        _ ->
            crossbar_util:response(error, <<"invalid credentials">>, 401, Context)
    end;
authorize_user(Context, Credentials, <<"sha">>) ->    
    case crossbar_doc:load_view(?SHA1_LIST, [{<<"key">>, Credentials}], Context#cb_context{db_name=?AGG_DB}) of
        #cb_context{resp_status=success, doc=JObj}=C1 when JObj =/= []->
            C1;
        _ ->
            crossbar_util:response(error, <<"invalid credentials">>, 401, Context)
    end;
authorize_user(Context, _, _) ->
    crossbar_util:response(error, <<"invalid credentials">>, 401, Context).    

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to create a token and save it to the token db
%% @end
%%--------------------------------------------------------------------
-spec(create_token/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> #cb_context{}).
create_token(RD, #cb_context{doc=[JObj]}=Context) ->
    create_token(RD, Context#cb_context{doc=JObj});
create_token(RD, #cb_context{doc=JObj}=Context) ->
    Value = whapps_json:get_value(<<"value">>, JObj),
    Token = {struct, [
                       {<<"account_id">>, whapps_json:get_value(<<"account_id">>, Value)}
                      ,{<<"user_id">>, whapps_json:get_value(<<"id">>, Value)}
                      ,{<<"api_id">>, <<"">>}
                      ,{<<"secret">>, whapps_json:get_value(<<"password">>, Value)}
                      ,{<<"created">>, calendar:datetime_to_gregorian_seconds(calendar:universal_time())}
                      ,{<<"modified">>, calendar:datetime_to_gregorian_seconds(calendar:universal_time())}
                      ,{<<"peer">>, whistle_util:to_binary(wrq:peer(RD))}
                      ,{<<"user-agent">>, whistle_util:to_binary(wrq:get_req_header("User-Agent", RD))}
                      ,{<<"accept">>, whistle_util:to_binary(wrq:get_req_header("Accept", RD))}
                      ,{<<"accept-charset">>, whistle_util:to_binary(wrq:get_req_header("Accept-Charset", RD))}
                      ,{<<"accept-endocing">>, whistle_util:to_binary(wrq:get_req_header("Accept-Encoding", RD))}
                      ,{<<"accept-language">>, whistle_util:to_binary(wrq:get_req_header("Accept-Language", RD))}
                      ,{<<"connection">>, whistle_util:to_binary(wrq:get_req_header("Conntection", RD))}
                      ,{<<"keep-alive">>, whistle_util:to_binary(wrq:get_req_header("Keep-Alive", RD))}
                     ]},
    case couch_mgr:save_doc(?TOKEN_DB, Token) of
        {ok, Doc} ->
            AuthToken = whapps_json:get_value(<<"_id">>, Doc),
            crossbar_util:response([], Context#cb_context{auth_token=AuthToken, auth_doc=Doc});
        {error, _} ->
            crossbar_util:response(error, <<"invalid credentials">>, 401, Context)
    end.
