open Reader_port

type wrong_clock = { now_s : unit -> int }
type wrong_env = {
  clock : wrong_clock;
  released : bool ref;
  users : users;
}

let bad =
  {
    clock = { now_s = (fun () -> 42) };
    released = ref false;
    users = { first = "alice"; second = "bob" };
  }

let _must_not_compile = Reader.run bad program
