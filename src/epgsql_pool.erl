-module(epgsql_pool).

-export([start/4, stop/1,
         validate_connection_params/1,
         query/2, query/3, query/4,
         transaction/2,
         get_settings/0, set_settings/1
        ]).

-include("epgsql_pool.hrl").

-type(pool_name() :: binary() | string() | atom()).
-export_type([pool_name/0]).


%% Module API

-spec start(pool_name(), integer(), integer(), map() | #epgsql_connection_params{}) -> {ok, pid()}.
start(PoolName, InitCount, MaxCount, ConnectionParams) when is_map(ConnectionParams) ->
    Params2 = #epgsql_connection_params{
                 host = maps:get(host, ConnectionParams),
                 port = maps:get(port, ConnectionParams),
                 username = maps:get(username, ConnectionParams),
                 password = maps:get(password, ConnectionParams),
                 database = maps:get(database, ConnectionParams)
                },
    start(PoolName, InitCount, MaxCount, Params2);

start(PoolName0, InitCount, MaxCount, #epgsql_connection_params{} = ConnectionParams) ->
    PoolName = epgsql_pool_utils:pool_name_to_atom(PoolName0),
    %% TODO check PoolName not in all_keys()
    application:set_env(epgsql_pool, PoolName, ConnectionParams),
    {ok, MaxQueue} = application:get_env(epgsql_pool, pooler_max_queue),
    PoolConfig = [{name, PoolName},
                  {init_count, InitCount},
                  {max_count, MaxCount},
                  {queue_max, MaxQueue},
                  {start_mfa, {epgsql_pool_worker, start_link, [PoolName]}},
                  {stop_mfa, {epgsql_pool_worker, stop, []}}
                 ],
    pooler:new_pool(PoolConfig).


-spec stop(pool_name()) -> ok | {error, term()}.
stop(PoolName) ->
    pooler:rm_pool(epgsql_pool_utils:pool_name_to_atom(PoolName)).


-spec validate_connection_params(map() | #epgsql_connection_params{}) -> ok | {error, term()}.
validate_connection_params(ConnectionParams) when is_map(ConnectionParams) ->
    Params2 = #epgsql_connection_params{
                 host = maps:get(host, ConnectionParams),
                 port = maps:get(port, ConnectionParams),
                 username = maps:get(username, ConnectionParams),
                 password = maps:get(password, ConnectionParams),
                 database = maps:get(database, ConnectionParams)
                },
    validate_connection_params(Params2);

validate_connection_params(#epgsql_connection_params{host = Host, port = Port, username = Username,
                                                     password = Password, database = Database}) ->
    {ok,ConnectionTimeout} = application:get_env(epgsql_pool, connection_timeout),
    Res = epgsql:connect(Host, Username, Password,
                         [{port, Port},
                          {database, Database},
                          {timeout, ConnectionTimeout}]),
    case Res of
        {ok, Sock} -> epgsql:close(Sock), ok;
        {error, Reason} -> {error, Reason}
    end.


-spec query(pool_name() | pid(), epgsql:sql_query()) -> epgsql:reply().
query(PoolNameOrWorker, Stmt) ->
    query(PoolNameOrWorker, Stmt, [], []).


-spec query(pool_name() | pid(), epgsql:sql_query(), [epgsql:bind_param()]) -> epgsql:reply().
query(PoolNameOrWorker, Stmt, Params) ->
    query(PoolNameOrWorker, Stmt, Params, []).


-spec query(pool_name() | pid(), epgsql:sql_query(), [epgsql:bind_param()], [proplists:option()]) -> epgsql:reply().
query(Worker, Stmt, Params, Options) when is_pid(Worker) ->
    Timeout = case proplists:get_value(timeout, Options) of
                  undefined -> element(2, application:get_env(epgsql_pool, query_timeout));
                  V -> V
              end,
    Sock = gen_server:call(Worker, get_sock),
    try
        gen_server:call(Worker, {equery, Stmt, Params}, Timeout)
    catch
        exit:{timeout, _} ->
            error_logger:error_msg("query timeout ~p ~p", [Stmt, Params]),
            epgsql_sock:cancel(Sock),
            {error, timeout}
    end;

query(PoolName0, Stmt, Params, Options) ->
    PoolName = epgsql_pool_utils:pool_name_to_atom(PoolName0),
    case get_worker(PoolName) of
        {ok, Worker} ->
            try
                query(Worker, Stmt, Params, Options)
            catch
                Err:Reason ->
                    erlang:raise(Err, Reason, erlang:get_stacktrace())
            after
                pooler:return_member(PoolName, Worker, ok)
            end;
        {error, Reason} -> {error, Reason}
    end.


-spec transaction(pool_name(), fun()) -> epgsql:reply() | {error, term()}.
transaction(PoolName0, Fun) ->
    PoolName = epgsql_pool_utils:pool_name_to_atom(PoolName0),
    case get_worker(PoolName) of
        {ok, Worker} ->
            try
                gen_server:call(Worker, {squery, "BEGIN"}),
                Result = Fun(Worker),
                gen_server:call(Worker, {squery, "COMMIT"}),
                Result
            catch
                Err:Reason ->
                    gen_server:call(Worker, {squery, "ROLLBACK"}),
                    erlang:raise(Err, Reason, erlang:get_stacktrace())
            after
                pooler:return_member(PoolName, Worker, ok)
            end;
        {error, Reason} -> {error, Reason}
    end.


-spec get_settings() -> map().
get_settings() ->
    lists:foldl(fun(Key, Map) ->
                        maps:put(Key, element(2, application:get_env(epgsql_pool, Key)), Map)
                end, maps:new(), all_keys()).


-spec set_settings(map()) -> ok.
set_settings(Map) ->
    lists:foreach(fun(Key) ->
                          case maps:find(Key, Map) of
                              {ok, Value} -> application:set_env(epgsql_pool, Key, Value);
                              error -> do_nothing
                          end
                  end, all_keys()),
    ok.


%%% inner functions

-spec get_worker(pool_name()) -> {ok, pid()} | {error, term()}.
get_worker(PoolName) ->
    {ok, Timeout} = application:get_env(epgsql_pool, pooler_get_worker_timeout),
    case pooler:take_member(PoolName, Timeout) of
        Worker when is_pid(Worker) -> {ok, Worker};
        error_no_members ->
            PoolStats = pooler:pool_stats(PoolName),
            error_logger:error_msg("Pool ~p overload: ~p", [PoolName, PoolStats]),
            {error, pool_overload}
    end.


-spec all_keys() -> [atom()].
all_keys() ->
    [connection_timeout, query_timeout,
     pooler_get_worker_timeout, pooler_max_queue,
     max_reconnect_timeout, min_reconnect_timeout, keep_alive_timeout].
