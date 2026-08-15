(* Typed coeffect contracts.

   A coeffect key is a generative [Type.Id] identity plus a unique runtime
   integer for cheap comparisons. The diagnostic name never participates in
   identity. The value-equivalence function is retained for executable
   recovery-contract verification only; the runtime never uses it to select a
   provider or to preserve an activation generation. *)

let uid_source = Atomic.make 0
let fresh_uid () = Atomic.fetch_and_add uid_source 1

type 'value t = {
  uid : int;
  id : 'value Type.Id.t;
  name : string;
  equivalent : 'value -> 'value -> bool;
}

type 'value contract = 'value t

let create ~name ~equivalent () =
  { uid = fresh_uid (); id = Type.Id.make (); name; equivalent }

let name t = t.name
let uid t = t.uid
let equivalent t = t.equivalent

(* Explicit coercion through an equality witness. Matching [Type.Equal] at
   the use site would introduce an ambient equation whose scope cannot cover
   a second existential; applying the witness as a function keeps the
   coercion local to one expression. *)
let cast : type a b. (a, b) Type.eq -> a -> b = fun Type.Equal value -> value

(** Type-erased key for heterogeneous maps and duplicate detection. *)
module Key = struct
  type t = K : _ contract -> t

  let uid (K c) = c.uid
  let name (K c) = c.name
  let equal a b = Int.equal (uid a) (uid b)
  let compare a b = Int.compare (uid a) (uid b)
end

let key t = Key.K t

(* Existential typed binding stored in provider episodes. Lookup compares the
   stored [Type.Id] and uses its equality witness to recover the payload type.
   No [Obj] operation appears anywhere in the package. *)
type binding = Binding : 'value contract * 'value -> binding

let binding contract value = Binding (contract, value)

let lookup : type a. a contract -> binding -> a option =
 fun contract (Binding (stored, value)) ->
  match Type.Id.provably_equal contract.id stored.id with
  | Some Type.Equal -> Some value
  | None -> None

let binding_key (Binding (contract, _)) = Key.K contract

module Interception = struct
  type ('value, 'metadata) t = {
    coeffect : 'value contract;
    metadata_id : 'metadata Type.Id.t;
    empty : 'metadata;
    merge : 'metadata -> 'metadata -> 'metadata;
    wrap : sample:(unit -> 'metadata) -> 'value -> 'value;
  }

  let create ~name ~equivalent ~empty ~merge ~wrap () =
    {
      coeffect = create ~name ~equivalent ();
      metadata_id = Type.Id.make ();
      empty;
      merge;
      wrap;
    }

  let coeffect t = t.coeffect
  let metadata_id t = t.metadata_id
  let empty t = t.empty
  let merge t = t.merge
  let wrap t = t.wrap
end
