module Q = Eta_sql

let tx_only (_runner : Q.Eta_pool.tx Q.Eta_pool.runner) = ()

let use_pool_runner (pool : Q.Eta_pool.t) =
  tx_only pool
