open Effet

let env =
  object
    method clock_now n = n
    method user_read n = n
    method user_write n = n
    method order_read n = n
    method order_write n = n
    method billing_refund n = n
    method audit_log n = n
    method cache_get n = n
    method cache_set n = n
    method search_query n = n
    method notify_send n = n
    method feature_flag n = n
    method config_get n = n
    method metrics_count n = n
    method auth_check n = n
    method session_get n = n
    method inventory_get n = n
    method shipment_quote n = n
    method email_send n = n
    method sms_send n = n
    method report_build n = n
    method policy_eval n = n
    method tenant_lookup n = n
    method rate_limit n = n
  end

let _ = Tp_common.run_with_env env (Tp_top.program ())
