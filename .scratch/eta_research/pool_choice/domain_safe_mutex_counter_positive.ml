module PA = Portable.Atomic

let mutex = Mutex.create ()

let counter = PA.make 0

let incr_under_mutex () =
  Mutex.lock mutex;
  PA.incr counter;
  Mutex.unlock mutex

let () =
  let domain = Domain.Safe.spawn incr_under_mutex in
  Domain.join domain;
  if PA.get counter <> 1 then failwith "expected counter increment";
  print_endline "domain_safe_mutex_counter_positive PASS"
