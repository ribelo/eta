type ('env, 'err, 'a) t = {
  load : ('env, 'err, 'a) Effect.t;
  mutable value : 'a option;
}

let refresh resource =
  resource.load
  |> Effect.map (fun value ->
         resource.value <- Some value)

let get resource =
  match resource.value with
  | Some value -> Effect.pure value
  | None ->
      resource.load
      |> Effect.map (fun value ->
             resource.value <- Some value;
             value)

let manual load =
  load |> Effect.map (fun value -> { load; value = Some value })
