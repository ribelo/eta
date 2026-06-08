(* PQ001: Type.Id heterogeneous service map with zero Obj.obj.
   Models runtime_core.ml `services` lookup, but type-safe. *)

module Dict : sig
  type t
  type 'a key
  val key : unit -> 'a key
  val empty : t
  val add : 'a key -> 'a -> t -> t
  val find : 'a key -> t -> 'a option
end = struct
  type 'a key = 'a Type.Id.t
  type binding = B : 'a key * 'a -> binding
  type t = (int * binding) list
  let key () = Type.Id.make ()
  let empty = []
  let add k v d = (Type.Id.uid k, B (k, v)) :: d
  let find : type a. a key -> t -> a option =
   fun k d ->
    match List.assoc_opt (Type.Id.uid k) d with
    | None -> None
    | Some (B (k', v)) -> (
        match Type.Id.provably_equal k k' with
        | Some Type.Equal -> Some v
        | None -> None)
end

(* a "service" with a structured type, like a logger/clock capability *)
type clock = { now : unit -> int }

let () =
  let clock_key : clock Dict.key = Dict.key () in
  let int_key : int Dict.key = Dict.key () in
  let d = Dict.empty in
  let d = Dict.add clock_key { now = (fun () -> 42) } d in
  let d = Dict.add int_key 7 d in
  (match Dict.find clock_key d with
   | Some c -> Printf.printf "001 clock service: now=%d\n" (c.now ())
   | None -> print_endline "001 FAIL: clock missing");
  (match Dict.find int_key d with
   | Some n -> Printf.printf "001 int service: %d\n" n
   | None -> print_endline "001 FAIL: int missing");
  (* miss returns None, no crash *)
  let absent : string Dict.key = Dict.key () in
  (match Dict.find absent d with
   | None -> print_endline "001 absent -> None (ok)"
   | Some _ -> print_endline "001 FAIL: phantom hit");
  print_endline "001 PASS: heterogeneous map, zero Obj.obj"
