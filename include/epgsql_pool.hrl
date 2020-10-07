
-record(epgsql_connection_params, {
          host :: string() | binary(),
          port :: non_neg_integer(),
          username :: string() | binary(),
          password :: string() | binary(),
          database :: string() | binary()
         }).

-record(epgsql_connection, {
          sock :: pid() | undefined,
          params :: #epgsql_connection_params{} | undefined,
          reconnect_attempt = 0 :: non_neg_integer()
         }).

-record(epgsql_query_stat, {
          get_worker_time :: non_neg_integer(),
          query_time :: non_neg_integer()
         }).