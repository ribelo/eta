open Effet

let services = Dx_common.make_services ()

let _ : (<  >, string, int) Effect.t =
  Args_top.program
    ~user_query:services#user_query
    ~user_get:services#user_get
    ~user_run:services#user_run
    ~user_fetch:services#user_fetch
    ~order_query:services#order_query
    ~order_get:services#order_get
    ~order_run:services#order_run
    ~order_fetch:services#order_fetch
    ~cache_query:services#cache_query
    ~cache_get:services#cache_get
    ~cache_run:services#cache_run
    ~cache_fetch:services#cache_fetch
    ~billing_query:services#billing_query
    ~billing_get:services#billing_get
    ~billing_run:services#billing_run
    ~audit_query:services#audit_query
    ~audit_get:services#audit_get
    ~audit_run:services#audit_run
    ~audit_fetch:services#audit_fetch
    ~search_query:services#search_query
    ~search_get:services#search_get
    ~search_run:services#search_run
    ~search_fetch:services#search_fetch
    ~notify_query:services#notify_query
    ~notify_get:services#notify_get
    ~notify_run:services#notify_run
    ~notify_fetch:services#notify_fetch
    ~feature_query:services#feature_query
    ~feature_get:services#feature_get
