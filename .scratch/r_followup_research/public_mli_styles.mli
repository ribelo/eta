open Effet

type clock = Services.clock
type log = Services.log
type result = string

class type clock_log = object
  method clock : clock
  method log : log
end

(** Open env-row requirement, exported as a thunk to avoid value-restriction
    surprises for reusable module-level effects. *)
val open_row_thunk :
  unit -> (< clock : clock ; log : log ; .. >, string, result) Effect.t

(** Closed object row. Compact, but rejects envs that carry extra capabilities. *)
val closed_row_value : (< clock : clock ; log : log >, string, result) Effect.t

(** Ordinary service arguments erase the env requirement after construction. *)
val args :
  clock:clock -> log:log -> ('env, string, result) Effect.t

(** A class-type bag is readable, but hides per-effect dependency precision. *)
val bag :
  #clock_log -> ('env, string, result) Effect.t
