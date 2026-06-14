(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** HTTP/2 priority scheduler, H2O-style dependency tree with weighted
    round-robin dispatch. *)

type t
(** The root of the dependency tree. *)

type ref
(** A stream's scheduling entry. *)

val id : ref -> int
(** Unique identifier for this scheduling ref. *)

val create : unit -> t

(** Open a scheduling reference with the given identifier as a child of
    [parent] with the given weight. [exclusive] causes existing siblings to be
    moved under the new ref. *)
val open_ref : id:int -> parent:t -> weight:int -> exclusive:bool -> ref

(** Close a ref and migrate its dependents to its parent. *)
val close_ref : ref -> unit

(** Change the parent/weight of an open ref. *)
val rebind : ref -> parent:t -> weight:int -> exclusive:bool -> unit

(** Mark a ref as having data to send. *)
val activate : t -> ref -> unit

(** Mark a ref as having no data to send (but keep it in the tree). *)
val deactivate : t -> ref -> unit

(** Visit refs in scheduling order, calling [f] for each active ref. [f]
    returns whether the ref is still active. The traversal stops early if
    [f] returns [Stop]. *)
val run : t -> f:(ref -> [ `Continue of bool | `Stop ]) -> [ `Stopped | `Done ]

val is_active : t -> bool
