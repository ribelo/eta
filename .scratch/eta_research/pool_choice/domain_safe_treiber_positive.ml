module PA = Portable.Atomic

type node = { value : int; next : node option }

let stack : node option PA.t = PA.make None

let rec push value =
  let next = PA.get stack in
  let node = Some { value; next } in
  match PA.compare_and_set stack ~if_phys_equal_to:next ~replace_with:node with
  | PA.Compare_failed_or_set_here.Set_here -> ()
  | PA.Compare_failed_or_set_here.Compare_failed -> push value

let rec pop () =
  match PA.get stack with
  | None -> None
  | Some node as current -> (
      match
        PA.compare_and_set stack ~if_phys_equal_to:current
          ~replace_with:node.next
      with
      | PA.Compare_failed_or_set_here.Set_here -> Some node.value
      | PA.Compare_failed_or_set_here.Compare_failed -> pop ())

let () =
  push 0;
  let domain = Domain.Safe.spawn (fun () -> push 1) in
  Domain.join domain;
  match (pop (), pop ()) with
  | Some _, Some _ ->
      print_endline "domain_safe_treiber_positive PASS"
  | _ ->
      failwith "expected two values"
