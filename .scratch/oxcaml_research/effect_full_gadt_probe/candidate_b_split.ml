(* Candidate B: split the portable core from same-domain/runtime I/O nodes. *)

open! Portable
open Common

module Effect_pure = struct
  type ('env : value mod portable contended, 'err : immutable_data, 'a : immutable_data) t =
    | Pure : 'a -> ('env, 'err, 'a) t
    | Fail : 'err -> ('env, 'err, _) t
    | Thunk :
        string * ('env -> 'a) @@ portable
        -> ('env, _, 'a) t
    | Bind :
        ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) @@ portable
        -> ('env, 'err, 'a) t
    | Map :
        ('env, 'err, 'b) t * ('b -> 'a) @@ portable
        -> ('env, 'err, 'a) t
    | Catch :
        ('env, 'err1, 'a) t * ('err1 -> ('env, 'err2, 'a) t) @@ portable
        -> ('env, 'err2, 'a) t
end

module Effect_io = struct
  type ('env, 'err, 'a) pure = ('env, 'err, 'a) Effect_pure.t

  type ('env, 'err, 'a) t =
    | Pure_portable : ('env, 'err, 'a) pure -> ('env, 'err, 'a) t
    | Delay : Duration.t * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Timeout :
        Duration.t * ('env, 'err, 'a) t -> ('env, [> `Timeout ] as 'err, 'a) t
    | Concat : ('env, 'err, unit) t list -> ('env, 'err, unit) t
    | Race : ('env, 'err, 'a) t list -> ('env, 'err, 'a) t
    | Par :
        ('env, 'err, 'a) t * ('env, 'err, 'b) t
        -> ('env, 'err, 'a * 'b) t
    | All : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
    | All_settled :
        ('env, 'err, 'a) t list
        -> ('env, _, ('a, 'err Cause.t) result list) t
    | For_each_par :
        'x list * ('x -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a list) t
    | For_each_par_bounded :
        int * 'x list * ('x -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a list) t
    | Daemon : ('env, 'err, unit) t -> ('env, 'err, unit) t
    | Uninterruptible : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Repeat : ('env, 'err, unit) t * Schedule.t -> ('env, 'err, unit) t
    | Retry :
        ('env, 'err, 'a) t * Schedule.t * ('err -> bool)
        -> ('env, 'err, 'a) t
    | Acquire_release :
        ('env, 'err, 'a) t * ('a -> ('env, 'err, unit) t)
        -> ('env, 'err, 'a) t
    | Scoped : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Supervisor_scoped :
        int option * ('env, 'err, 'a) supervisor_body
        -> ('env, 'err, 'a) t
    | Render_error : ('err -> string) * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Named :
        Capabilities.span_kind * string * ('env, 'err, 'a) t
        -> ('env, 'err, 'a) t
    | Annotate : string * string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Link_span :
        Capabilities.span_link * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | With_external_parent :
        Capabilities.trace_context * ('env, 'err, 'a) t
        -> ('env, 'err, 'a) t
    | With_context :
        Capabilities.trace_context * ('env, 'err, 'a) t
        -> ('env, 'err, 'a) t
    | Current_span : ('env, 'err, Capabilities.span_info option) t
    | Current_context : ('env, 'err, Capabilities.trace_context option) t
    | Log :
        Capabilities.log_level * string * (string * string) list
        -> ('env, 'err, unit) t
    | Metric_update : {
        name : string;
        description : string;
        unit_ : string;
        kind : Capabilities.metric_kind;
        attrs : (string * string) list;
        value : Capabilities.metric_value;
      }
        -> ('env, 'err, unit) t

  and ('s, 'env, 'err, 'a) supervisor_scope =
    | Supervisor_pure : 'a -> (_, _, _, 'a) supervisor_scope
    | Supervisor_lift :
        ('env, 'err, 'a) t -> (_, 'env, 'err, 'a) supervisor_scope
    | Supervisor_fail : 'err -> (_, _, 'err, _) supervisor_scope
    | Supervisor_bind :
        ('s, 'env, 'err, 'b) supervisor_scope
        * ('b -> ('s, 'env, 'err, 'a) supervisor_scope)
        -> ('s, 'env, 'err, 'a) supervisor_scope
    | Supervisor_start :
        ('s, 'err) supervisor
        * ('s, 'env, 'err, 'a) supervisor_scope
        -> ('s, 'env, _, ('s, 'err, 'a) supervisor_child) supervisor_scope
    | Supervisor_await :
        ('s, 'err, 'a) supervisor_child -> ('s, _, 'err, 'a) supervisor_scope
    | Supervisor_cancel :
        ('s, _, _) supervisor_child -> ('s, _, _, unit) supervisor_scope
    | Supervisor_failures :
        ('s, 'err) supervisor -> ('s, _, _, 'err Cause.t list) supervisor_scope
    | Supervisor_check :
        ('s, [> `Supervisor_failed of int ] as 'err) supervisor
        -> ('s, _, 'err, unit) supervisor_scope
    | Supervisor_yield : ('s, _, _, unit) supervisor_scope

  and ('env, 'err, 'a) supervisor_body = {
    run :
      's.
      ('s, 'err) supervisor -> ('s, 'env, 'err, 'a) supervisor_scope;
  }

  and ('s, !'err) supervisor = {
    sw : Eio.Switch.t;
    max_failures : int option;
    failures : 'err Cause.t list ref;
  }

  and ('s, !'err, !'a) supervisor_child = {
    promise : ('a, 'err Cause.t) result Eio.Promise.t;
    cancel : unit -> unit;
  }
end

let portable_program : (unit, string, int) Effect_pure.t =
  Effect_pure.Bind (Effect_pure.Pure 1, fun n -> Effect_pure.Pure (n + 1))

let io_program : (unit, string, int) Effect_io.t =
  Effect_io.Pure_portable portable_program

let () =
  ignore portable_program;
  ignore io_program

