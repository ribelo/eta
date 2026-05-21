open! Portable

let () =
  let counter = Atomic.make 0 in
  Atomic.incr counter;
  Atomic.decr counter;
  if Atomic.get counter <> 0 then failwith "portable atomic counter changed"
