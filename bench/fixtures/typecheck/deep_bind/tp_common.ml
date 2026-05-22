open Eta

class type services = object
  method clock_now : int -> int
  method user_read : int -> int
  method user_write : int -> int
  method order_read : int -> int
  method order_write : int -> int
  method billing_charge : int -> int
  method billing_refund : int -> int
  method audit_log : int -> int
  method cache_get : int -> int
  method cache_set : int -> int
  method search_query : int -> int
  method notify_send : int -> int
  method feature_flag : int -> int
  method config_get : int -> int
  method metrics_count : int -> int
  method auth_check : int -> int
  method session_get : int -> int
  method inventory_get : int -> int
  method shipment_quote : int -> int
  method email_send : int -> int
  method sms_send : int -> int
  method report_build : int -> int
  method policy_eval : int -> int
  method tenant_lookup : int -> int
  method rate_limit : int -> int
end

let make_services () =
  object
    method clock_now n = n + 1
    method user_read n = n + 2
    method user_write n = n + 3
    method order_read n = n + 4
    method order_write n = n + 5
    method billing_charge n = n + 6
    method billing_refund n = n + 7
    method audit_log n = n + 8
    method cache_get n = n + 9
    method cache_set n = n + 10
    method search_query n = n + 11
    method notify_send n = n + 12
    method feature_flag n = n + 13
    method config_get n = n + 14
    method metrics_count n = n + 15
    method auth_check n = n + 16
    method session_get n = n + 17
    method inventory_get n = n + 18
    method shipment_quote n = n + 19
    method email_send n = n + 20
    method sms_send n = n + 21
    method report_build n = n + 22
    method policy_eval n = n + 23
    method tenant_lookup n = n + 24
    method rate_limit n = n + 25
  end

let run_with_env env eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env () in
  Runtime.run rt eff

let ok = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      failwith (Format.asprintf "unexpected failure: %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>")) cause)

let schedule = Schedule.recurs 0
let tiny = Duration.ms 1
