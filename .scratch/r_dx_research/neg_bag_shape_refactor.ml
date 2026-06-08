let services =
  object
  method user_query n = n + 1
  method user_get n = n + 2
  method user_run n = n + 3
  method user_fetch n = n + 4
  method order_query n = n + 5
  method order_get n = n + 6
  method order_run n = n + 7
  method order_fetch n = n + 8
  method cache_query n = n + 9
  method cache_get n = n + 10
  method cache_run n = n + 11
  method cache_fetch n = n + 12
  method billing_query n = n + 13
  method billing_get n = n + 14
  method billing_run n = n + 15
  method billing_fetch s = String.length s
  method audit_query n = n + 17
  method audit_get n = n + 18
  method audit_run n = n + 19
  method audit_fetch n = n + 20
  method search_query n = n + 21
  method search_get n = n + 22
  method search_run n = n + 23
  method search_fetch n = n + 24
  method notify_query n = n + 25
  method notify_get n = n + 26
  method notify_run n = n + 27
  method notify_fetch n = n + 28
  method feature_query n = n + 29
  method feature_get n = n + 30
  end

let _ = Bag_top.program services
