open Eta

let coordinate first continue =
  Effect.Expert.make ~capabilities:[ `Concurrency ]
    ~leaf_name:"app.coordinate" @@ fun context ->
  let contract = Effect.Expert.contract context in
  let scope = Effect.Expert.current_scope context in
  let promise, resolver = contract.Runtime_contract.create_promise () in
  contract.Runtime_contract.fork scope (fun () ->
      let exit = Effect.Expert.eval context first in
      contract.Runtime_contract.resolve_promise resolver exit);
  match contract.Runtime_contract.await_promise promise with
  | Exit.Ok value -> Effect.Expert.eval context (continue value)
  | Exit.Error _ as error -> error
