(* Candidate C: a mode-polymorphic template over portable/nonportable.

   This tests whether one source definition can be parameterised by the
   portability modality instead of splitting the AST manually. *)

open! Portable
open Common

[%%template
[@@@modality.default p = (nonportable, portable)]

type ('env : value mod p contended, 'err : immutable_data, 'a : immutable_data) t
  : value mod p contended =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Fail : 'err -> ('env, 'err, _) t
  | Thunk :
      string * ('env -> 'a) @@ p
      -> ('env, _, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) @@ p
      -> ('env, 'err, 'a) t
  | Map :
      ('env, 'err, 'b) t * ('b -> 'a) @@ p
      -> ('env, 'err, 'a) t
  | Catch :
      ('env, 'err1, 'a) t * ('err1 -> ('env, 'err2, 'a) t) @@ p
      -> ('env, 'err2, 'a) t
  | Delay : Duration.t * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | All_settled :
      ('env, 'err, 'a) t list
      -> ('env, _, ('a, 'err Cause.t) result list) t
  | Supervisor_scoped :
      int option * ('env, 'err, 'a) supervisor_body
      -> ('env, 'err, 'a) t

and ('s, 'env : value mod p contended, 'err : immutable_data, 'a : immutable_data)
    supervisor_scope =
  | Supervisor_pure : 'a -> (_, _, _, 'a) supervisor_scope
  | Supervisor_lift :
      ('env, 'err, 'a) t -> (_, 'env, 'err, 'a) supervisor_scope
  | Supervisor_bind :
      ('s, 'env, 'err, 'b) supervisor_scope
      * ('b -> ('s, 'env, 'err, 'a) supervisor_scope) @@ p
      -> ('s, 'env, 'err, 'a) supervisor_scope

and ('env : value mod p contended, 'err : immutable_data, 'a : immutable_data)
    supervisor_body = {
  run :
    's.
    ('s, 'err) supervisor -> ('s, 'env, 'err, 'a) supervisor_scope;
}

and ('s, !'err) supervisor = {
  sw : Eio.Switch.t;
  max_failures : int option;
  failures : 'err Cause.t list ref;
}]

let () = ()

