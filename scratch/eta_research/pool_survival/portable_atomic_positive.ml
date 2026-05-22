open Portable

type node = {
  value : int;
  next : node option;
}

let stack : node option Atomic.t = Atomic.make None

let rec push value =
  let next = Atomic.get stack in
  let node = Some { value; next } in
  match Atomic.compare_and_set stack ~if_phys_equal_to:next ~replace_with:node with
  | Atomic.Compare_failed_or_set_here.Set_here -> ()
  | Compare_failed -> push value

let rec pop () =
  match Atomic.get stack with
  | None -> None
  | Some node as current -> (
      match
        Atomic.compare_and_set stack ~if_phys_equal_to:current
          ~replace_with:node.next
      with
      | Atomic.Compare_failed_or_set_here.Set_here -> Some node.value
      | Compare_failed -> pop ())

let () =
  push 1;
  push 2;
  push 3;
  assert (pop () = Some 3);
  assert (pop () = Some 2);
  assert (pop () = Some 1);
  assert (pop () = None);
  print_endline "portable_atomic_positive PASS api=Portable.Atomic lifo=true"
