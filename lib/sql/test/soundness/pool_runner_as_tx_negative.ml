module Q = Eta_sql

let tx_only (_runner : Q.Pool.tx Q.Pool.runner) = ()

let use_pool_runner (pool : Q.Pool.t) =
  tx_only pool
