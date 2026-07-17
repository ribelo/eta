open Types

let max_diagnostic_message_bytes = 256

let bound_text ~limit text =
  let text = Eta.String_helpers.trim text in
  let len = String.length text in
  if len <= limit then text
  else if limit <= 3 then String.sub text 0 limit
  else String.sub text 0 (limit - 3) ^ "..."

let contains_ci haystack needle =
  Eta.String_helpers.contains_ascii_ci haystack needle

let normalized_code = function
  | None -> None
  | Some code ->
      let code = Eta.String_helpers.lowercase_ascii_trim code in
      if String.equal code "" then None else Some code

let code_category = function
  | None -> None
  | Some code ->
      if
        contains_ci code "context_length"
        || contains_ci code "context_window"
        || contains_ci code "max_tokens"
        || contains_ci code "token_limit"
        || contains_ci code "context_overflow"
        || String.equal code "length"
      then Some Context_overflow
      else if
        contains_ci code "rate_limit"
        || contains_ci code "timeout"
        || contains_ci code "overloaded"
        || contains_ci code "server_error"
        || contains_ci code "internal_error"
        || contains_ci code "temporarily_unavailable"
        || contains_ci code "service_unavailable"
      then Some Transient
      else if
        contains_ci code "insufficient_quota"
        || contains_ci code "quota"
        || contains_ci code "budget"
        || contains_ci code "credit_balance"
      then Some Quota_budget
      else if
        contains_ci code "billing"
        || contains_ci code "payment"
        || contains_ci code "payment_required"
      then Some Billing
      else if
        contains_ci code "account"
        || contains_ci code "organization"
        || contains_ci code "org_limit"
        || contains_ci code "usage_limit"
        || contains_ci code "limit_exceeded"
      then Some Account_limit
      else None

let message_category message =
  if
    contains_ci message "context length"
    || contains_ci message "context window"
    || contains_ci message "maximum context"
    || contains_ci message "max context"
    || contains_ci message "too many tokens"
    || contains_ci message "prompt is too long"
    || contains_ci message "context_length_exceeded"
  then Some Context_overflow
  else if
    contains_ci message "insufficient_quota"
    || contains_ci message "quota"
    || contains_ci message "budget"
    || contains_ci message "credit balance"
  then Some Quota_budget
  else if
    contains_ci message "billing"
    || contains_ci message "payment required"
    || contains_ci message "payment method"
    || contains_ci message "add a payment"
  then Some Billing
  else if
    contains_ci message "account limit"
    || contains_ci message "organization limit"
    || contains_ci message "usage limit"
    || contains_ci message "limit exceeded"
  then Some Account_limit
  else if
    contains_ci message "rate limit"
    || contains_ci message "too many requests"
    || contains_ci message "temporarily unavailable"
    || contains_ci message "overloaded"
    || contains_ci message "try again"
  then Some Transient
  else None

let status_category = function
  | Some 408 | Some 429 -> Some Transient
  | Some 402 -> Some Billing
  | Some status when status >= 500 && status <= 599 -> Some Transient
  | _ -> None

let category_of ~status ~code ~message =
  match code_category (normalized_code code) with
  | Some category -> category
  | None -> (
      match status_category status with
      | Some category -> category
      | None -> (
          match message_category message with
          | Some category -> category
          | None -> Other))

let retryable_of_category = function
  | Transient -> true
  | Context_overflow | Account_limit | Quota_budget | Billing | Other -> false

let http_retryable error =
  match Eta_http.Error.retryability error with
  | Eta_http.Error.Retryable | Eta_http.Error.Retryable_if_body_replayable ->
      true
  | Eta_http.Error.Not_retryable -> false

let parse_retry_after_seconds value =
  let value = Eta.String_helpers.trim value in
  if String.equal value "" then None
  else
    match int_of_string_opt value with
    | Some seconds when seconds >= 0 -> Some seconds
    | _ -> None

let retry_after_from_headers headers =
  match Eta_http.Core.Header.get "retry-after" headers with
  | None -> None
  | Some value -> parse_retry_after_seconds value

let retry_after_from_http_error error =
  match error.Eta_http.Error.kind with
  | Eta_http.Error.HTTP_status { headers; _ } ->
      retry_after_from_headers (Eta_http.Core.Header.unsafe_of_list headers)
  | _ -> None

let category_name = function
  | Transient -> "transient"
  | Context_overflow -> "context_overflow"
  | Account_limit -> "account_limit"
  | Quota_budget -> "quota_budget"
  | Billing -> "billing"
  | Other -> "other"

let append_field ~key value acc =
  match value with None -> acc | Some value -> (key ^ "=" ^ value) :: acc

let make_diagnostic ~kind ?provider ?status ?code ?feature ~message () =
  let parts =
    [ "kind=" ^ kind ]
    |> append_field ~key:"provider" provider
    |> append_field ~key:"status"
         (Option.map string_of_int status)
    |> append_field ~key:"code" (normalized_code code)
    |> append_field ~key:"feature" feature
  in
  let message = bound_text ~limit:max_diagnostic_message_bytes message in
  let parts =
    if String.equal message "" then parts
    else ("message=" ^ message) :: parts
  in
  String.concat " " (List.rev parts)

let project_http_error error =
  let status = Eta_http.Error.status error in
  let retry_after_s = retry_after_from_http_error error in
  let message = Eta_http.Error.to_string error in
  let category =
    match status_category status with
    | Some category -> category
    | None -> if http_retryable error then Transient else Other
  in
  let retryable =
    match category with
    | Transient -> true
    | Context_overflow | Account_limit | Quota_budget | Billing -> false
    | Other -> http_retryable error
  in
  {
    category;
    status;
    retryable;
    retry_after_s;
    diagnostic =
      make_diagnostic ~kind:"http_error" ?status ~message:message ();
  }

let project_provider_error ~provider ~status ~code ~message ~retry_after_s =
  let category = category_of ~status ~code ~message in
  {
    category;
    status;
    retryable = retryable_of_category category;
    retry_after_s;
    diagnostic =
      make_diagnostic ~kind:"provider_error" ~provider ?status ?code ~message
        ();
  }

let project_ai_error = function
  | Eta_http_error error -> project_http_error error
  | Provider_error
      { provider; status; code; message; raw = _; retry_after_s } ->
      project_provider_error ~provider ~status ~code ~message ~retry_after_s
  | Decode_error { provider; message; raw = _ } ->
      {
        category = Other;
        status = None;
        retryable = false;
        retry_after_s = None;
        diagnostic =
          make_diagnostic ~kind:"decode_error" ~provider ~message ();
      }
  | Invalid_tool { name; message } ->
      {
        category = Other;
        status = None;
        retryable = false;
        retry_after_s = None;
        diagnostic =
          make_diagnostic ~kind:"invalid_tool" ~provider:name ~message ();
      }
  | Unsupported { provider; feature } ->
      {
        category = Other;
        status = None;
        retryable = false;
        retry_after_s = None;
        diagnostic =
          make_diagnostic ~kind:"unsupported" ~provider ~feature
            ~message:("unsupported " ^ feature) ();
      }

let ai_error_category_to_string = category_name
