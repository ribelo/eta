(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Error = Server_error

module Body = struct
  type stream = {
    length : int option;
    read : unit -> (bytes option, Error.t) Eta.Effect.t;
    release : unit -> (unit, Error.t) Eta.Effect.t;
  }

  type t =
    | Empty
    | Fixed of bytes list
    | Stream of stream

  let empty = Empty
  let fixed chunks = Fixed (List.map Bytes.copy chunks)
  let string value = Fixed [ Bytes.of_string value ]

  let stream ?length ?(release = fun () -> Eta.Effect.unit) read =
    (match length with
    | Some length when length < 0 ->
        invalid_arg "Eta_http.Server.Response.Body.stream: length must be >= 0"
    | None | Some _ -> ());
    Stream { length; read; release }
end

type t = {
  status : int;
  headers : Header.t;
  body : Body.t;
  trailers : unit -> (Header.t, Error.t) Eta.Effect.t;
}

let validate_status status =
  match Status.of_int status with
  | Some status -> Status.to_int status
  | None ->
      invalid_arg
        "Eta_http.Server.Response.make: status must be in the range 100..599"

let validate_headers where headers =
  match Header.validate headers with
  | None -> headers
  | Some _ ->
      invalid_arg
        ("Eta_http.Server.Response." ^ where ^ ": invalid response header")

let make ?(headers = Header.empty)
    ?(trailers = fun () -> Eta.Effect.pure Header.empty) ~status ~body () =
  {
    status = validate_status status;
    headers = validate_headers "make" headers;
    body;
    trailers;
  }

let empty ?headers ~status () = make ?headers ~status ~body:Body.empty ()
let text ?headers ?(status = 200) value = make ?headers ~status ~body:(Body.string value) ()
let status t = t.status
let headers t = t.headers
let body t = t.body
let trailers t = t.trailers
