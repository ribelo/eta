module A = Eta_ai

let max_upload_bytes = 26_214_400L

let validate ~label source =
  match A.Audio.known_length source with
  | Some length when Int64.compare length max_upload_bytes > 0 ->
      Common.invalid_request
        (label
       ^ " upload exceeds the documented 25 MB (26,214,400 bytes) maximum")
  | None | Some _ -> Ok ()
