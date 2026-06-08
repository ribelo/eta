module Stack = struct
  type 'a node = {
    value : 'a;
    next : 'a node option;
  }

  type 'a t = 'a node option Atomic.t

  let create () = Atomic.make None

  let rec push t value =
    let next = Atomic.get t in
    let node = Some { value; next } in
    if not (Atomic.compare_and_set t next node) then push t value

  let rec pop t =
    match Atomic.get t with
    | None -> None
    | Some node as current ->
        if Atomic.compare_and_set t current node.next then Some node.value
        else pop t
end

let () =
  let stack = Stack.create () in
  Stack.push stack 1;
  Stack.push stack 2;
  Stack.push stack 3;
  assert (Stack.pop stack = Some 3);
  assert (Stack.pop stack = Some 2);
  assert (Stack.pop stack = Some 1);
  assert (Stack.pop stack = None);
  print_endline "treiber_stack_probe PASS lifo=true atomic=Stdlib.Atomic"
