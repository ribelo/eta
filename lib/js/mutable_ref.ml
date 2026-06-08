type 'a t = { mutable value : 'a }

let make value = { value }
let get t = t.value
let set t value = t.value <- value

let update t f = t.value <- f t.value

let update_and_get t f =
  let value = f t.value in
  t.value <- value;
  value

let get_and_set t value =
  let previous = t.value in
  t.value <- value;
  previous

let compare_and_set t expected desired =
  if t.value == expected then begin
    t.value <- desired;
    true
  end
  else false

let incr t = update t (fun value -> value + 1)
let decr t = update t (fun value -> value - 1)
