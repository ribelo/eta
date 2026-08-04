open Crux_graph

type slot_state =
  | Active of boundary_export
  | Tombstone

type slot = {
  mutable generation : int32;
  mutable state : slot_state;
}

type t = {
  session : int64;
  authentication_key : string;
  mutable next_slot : int;
  mutable free_slots : int list;
  slots : (int, slot) Hashtbl.t;
  active_exports : (int, int) Hashtbl.t;
}

type lookup =
  | Malformed
  | Unknown
  | Stale
  | Revoked
  | Found of boundary_export

let random_authentication_key () =
  let channel = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel 32)

let create ~session ~authentication_key =
  {
    session;
    authentication_key;
    next_slot = 0;
    free_slots = [];
    slots = Hashtbl.create 8;
    active_exports = Hashtbl.create 8;
  }

let handle_prefix ~session ~slot ~generation =
  let bytes = Bytes.create 20 in
  Bytes.blit_string "ECX1" 0 bytes 0 4;
  Bytes.set_int64_be bytes 4 session;
  Bytes.set_int32_be bytes 12 (Int32.of_int slot);
  Bytes.set_int32_be bytes 16 generation;
  bytes

let handle_authenticator registry prefix =
  Crux_sha256.hmac ~key:registry.authentication_key prefix

let make_handle registry ~slot ~generation =
  let prefix =
    handle_prefix ~session:registry.session ~slot ~generation
  in
  let handle = Bytes.create 36 in
  Bytes.blit prefix 0 handle 0 20;
  Bytes.blit_string
    (handle_authenticator registry prefix |> Bytes.to_string)
    0 handle 20 16;
  handle

let constant_time_equal left right =
  if String.length left <> String.length right then false
  else
    let difference = ref 0 in
    for index = 0 to String.length left - 1 do
      difference :=
        !difference
        lor (Char.code left.[index] lxor Char.code right.[index])
    done;
    !difference = 0

let lookup registry handle =
  if Bytes.length handle <> 36
     || Bytes.sub_string handle 0 4 <> "ECX1"
  then Malformed
  else
    let prefix = Bytes.sub handle 0 20 in
    let supplied_authenticator = Bytes.sub_string handle 20 16 in
    let expected_authenticator =
      handle_authenticator registry prefix
      |> fun bytes -> Bytes.sub_string bytes 0 16
    in
    if
      not
        (constant_time_equal supplied_authenticator
           expected_authenticator)
    then Unknown
    else
      let session = Bytes.get_int64_be handle 4 in
      let slot = Int32.to_int (Bytes.get_int32_be handle 12) in
      let generation = Bytes.get_int32_be handle 16 in
      if session <> registry.session then Stale
      else if slot < 0 || Int32.compare generation 0l <= 0 then
        Unknown
      else
        match Hashtbl.find_opt registry.slots slot with
        | None -> Unknown
        | Some current
          when Int32.compare generation current.generation < 0 ->
            Stale
        | Some current
          when Int32.compare generation current.generation > 0 ->
            Unknown
        | Some { state = Tombstone; _ } -> Revoked
        | Some { state = Active export; _ } -> Found export

let synchronize registry exports =
  let present =
    Int_map.fold
      (fun identity _ present -> Int_set.add identity present)
      exports Int_set.empty
  in
  Hashtbl.to_seq registry.active_exports
  |> List.of_seq
  |> List.iter (fun (identity, slot_number) ->
         if not (Int_set.mem identity present) then (
           Hashtbl.remove registry.active_exports identity;
           let slot = Hashtbl.find registry.slots slot_number in
           slot.state <- Tombstone;
           registry.free_slots <- slot_number :: registry.free_slots));
  Int_map.iter
    (fun identity export ->
      match Hashtbl.find_opt registry.active_exports identity with
      | Some slot_number ->
          let slot = Hashtbl.find registry.slots slot_number in
          slot.state <- Active export
      | None ->
          let slot_number =
            match registry.free_slots with
            | slot_number :: free_slots ->
                registry.free_slots <- free_slots;
                let slot =
                  Hashtbl.find registry.slots slot_number
                in
                if slot.generation = Int32.minus_one then
                  invalid_arg
                    "Eta_crux.Driver: remote handle generation exhausted";
                slot.generation <- Int32.add slot.generation 1l;
                slot.state <- Active export;
                slot_number
            | [] ->
                if registry.next_slot = max_int then
                  invalid_arg
                    "Eta_crux.Driver: remote handle slot exhausted";
                let slot_number = registry.next_slot in
                registry.next_slot <- slot_number + 1;
                Hashtbl.add registry.slots slot_number
                  { generation = 1l; state = Active export };
                slot_number
          in
          Hashtbl.add registry.active_exports identity slot_number)
    exports

let handles registry =
  Hashtbl.fold
    (fun identity slot_number handles ->
      let slot = Hashtbl.find registry.slots slot_number in
      Int_map.add identity
        (make_handle registry ~slot:slot_number
           ~generation:slot.generation)
        handles)
    registry.active_exports Int_map.empty
