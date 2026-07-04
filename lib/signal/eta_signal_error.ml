type graph_error =
  [ `Ambiguous_scope
  | `Counter_overflow of string
  | `Cycle
  | `Invalid_scope
  | `Reentrant_stabilization
  | `Runtime_mismatch
  | `Reentrant_update ]

type observer_read_error =
  [ `Disposed_observer
  | `Invalid_scope
  | `No_current_value
  | `Uninitialized_observer ]

type 'observer_error stabilize_error =
  [ graph_error | `Observer_error of 'observer_error ]

type time_error =
  [ graph_error | `Deadline_overflow | `Invalid_interval | `Past_deadline ]

type stream_error = [ graph_error | `Invalid_capacity ]

let pp_graph_error ppf = function
  | `Ambiguous_scope -> Format.pp_print_string ppf "ambiguous dynamic scope"
  | `Counter_overflow name ->
      Format.fprintf ppf "internal counter overflow: %s" name
  | `Cycle -> Format.pp_print_string ppf "cycle detected"
  | `Invalid_scope -> Format.pp_print_string ppf "invalid dynamic scope"
  | `Reentrant_stabilization ->
      Format.pp_print_string ppf "reentrant stabilization"
  | `Runtime_mismatch ->
      Format.pp_print_string ppf "timer used from a different Eta runtime"
  | `Reentrant_update ->
      Format.pp_print_string ppf "same-variable effectful update reentry"

let pp_observer_read_error ppf = function
  | `Disposed_observer -> Format.pp_print_string ppf "disposed observer"
  | `Invalid_scope -> Format.pp_print_string ppf "invalid dynamic scope"
  | `No_current_value -> Format.pp_print_string ppf "no current observer value"
  | `Uninitialized_observer ->
      Format.pp_print_string ppf "uninitialized observer"

let pp_stabilize_error pp_observer_error ppf = function
  | #graph_error as err -> pp_graph_error ppf err
  | `Observer_error err ->
      Format.fprintf ppf "observer callback failed: %a" pp_observer_error err

let rec observer_cause_to_stabilize :
    type observer_error.
    graph_error_of_die:(Eta.Cause.die -> graph_error option) ->
    observer_error Eta.Cause.t ->
    observer_error stabilize_error Eta.Cause.t =
 fun ~graph_error_of_die -> function
  | Eta.Cause.Fail err -> Eta.Cause.Fail (`Observer_error err)
  | Eta.Cause.Die die -> (
      match graph_error_of_die die with
      | Some err -> Eta.Cause.Fail (err :> observer_error stabilize_error)
      | None -> Eta.Cause.Die die)
  | Eta.Cause.Interrupt id -> Eta.Cause.Interrupt id
  | Eta.Cause.Sequential causes ->
      Eta.Cause.Sequential
        (List.map (observer_cause_to_stabilize ~graph_error_of_die) causes)
  | Eta.Cause.Concurrent causes ->
      Eta.Cause.Concurrent
        (List.map (observer_cause_to_stabilize ~graph_error_of_die) causes)
  | Eta.Cause.Finalizer cause -> Eta.Cause.Finalizer cause
  | Eta.Cause.Suppressed { primary; finalizer } ->
      Eta.Cause.Suppressed
        {
          primary = observer_cause_to_stabilize ~graph_error_of_die primary;
          finalizer;
        }

let pp_time_error ppf = function
  | #graph_error as err -> pp_graph_error ppf err
  | `Deadline_overflow ->
      Format.pp_print_string ppf "deadline arithmetic overflow"
  | `Invalid_interval -> Format.pp_print_string ppf "invalid interval"
  | `Past_deadline -> Format.pp_print_string ppf "deadline is in the past"

let pp_stream_error ppf = function
  | #graph_error as err -> pp_graph_error ppf err
  | `Invalid_capacity ->
      Format.pp_print_string ppf "stream bridge capacity must be positive"
