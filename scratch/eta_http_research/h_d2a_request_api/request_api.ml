open Eta

type error = Error.t
type protocol = H1 | H2
type headers = (string * string) list

let with_lock mutex f =
  Eio.Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock mutex) f

module Stream = struct
  type t = {
    chunks : string array;
    delay_per_chunk : Duration.t option;
    release : unit -> (unit, error) Effect.t;
    mutex : Eio.Mutex.t;
    mutable next : int;
    mutable released : bool;
  }

  type step = End | Chunk of string * bool

  let create ?delay_per_chunk ~release chunks =
    {
      chunks = Array.of_list chunks;
      delay_per_chunk;
      release;
      mutex = Eio.Mutex.create ();
      next = 0;
      released = false;
    }

  let release_once t =
    Effect.sync (fun () ->
        with_lock t.mutex @@ fun () ->
        if t.released then false
        else (
          t.released <- true;
          true))
    |> Effect.bind (function false -> Effect.unit | true -> t.release ())

  let take t =
    Effect.sync @@ fun () ->
    with_lock t.mutex @@ fun () ->
    if t.released || t.next >= Array.length t.chunks then End
    else
      let chunk = t.chunks.(t.next) in
      t.next <- t.next + 1;
      Chunk (chunk, t.next >= Array.length t.chunks)

  let maybe_delay = function
    | None -> Effect.unit
    | Some duration -> Effect.delay duration Effect.unit

  let read t =
    maybe_delay t.delay_per_chunk
    |> Effect.bind (fun () ->
           take t
           |> Effect.bind (function
                | End -> release_once t |> Effect.map (fun () -> None)
                | Chunk (chunk, last) ->
                    (if last then release_once t else Effect.unit)
                    |> Effect.map (fun () -> Some chunk)))

  let read_all t =
    let rec loop acc =
      read t
      |> Effect.bind (function
           | None -> Effect.pure (String.concat "" (List.rev acc))
           | Some chunk -> loop (chunk :: acc))
    in
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit
         ~release:(fun () -> release_once t)
      |> Effect.bind (fun () -> loop []))

  let discard = release_once
end

module Request = struct
  type body = Empty | Fixed of string list

  type t = {
    method_ : string;
    uri : string;
    headers : headers;
    body : body;
  }

  let make ?(headers = []) ?(body = Empty) method_ uri =
    { method_; uri; headers; body }

  let body_chunks t =
    match t.body with Empty -> 0 | Fixed chunks -> List.length chunks
end

module Response = struct
  type t = {
    status : int;
    headers : headers;
    body : Stream.t;
    trailers : unit -> (headers, error) Effect.t;
  }
end

module Stats = struct
  type t = {
    protocol : protocol;
    active : int;
    idle : int;
    capacity : int;
    opened : int;
    released : int;
    raw : string list;
  }

  let protocol_to_string = function H1 -> "h1" | H2 -> "h2"

  let to_lines t =
    Printf.sprintf
      "protocol=%s active=%d idle=%d capacity=%d opened=%d released=%d"
      (protocol_to_string t.protocol) t.active t.idle t.capacity t.opened
      t.released
    :: t.raw
end

module Client = struct
  type t = {
    protocol : protocol;
    request_impl : Request.t -> (Response.t, error) Effect.t;
    stats_impl : unit -> (Stats.t, error) Effect.t;
    shutdown_impl : unit -> (unit, error) Effect.t;
  }

  let protocol t = t.protocol
  let stats t = t.stats_impl ()
  let shutdown t = t.shutdown_impl ()
end

let request client req = client.Client.request_impl req

module Private = struct
  type response_plan = {
    status : int;
    headers : headers;
    chunks : string list;
    trailers : headers;
    delay_per_chunk : Duration.t option;
  }

  let make_client ~protocol ~request ~stats ~shutdown =
    {
      Client.protocol;
      request_impl = request;
      stats_impl = stats;
      shutdown_impl = shutdown;
    }

  let make_stream ?delay_per_chunk ~release chunks =
    Stream.create ?delay_per_chunk ~release chunks

  let body_text req =
    match req.Request.body with
    | Empty -> ""
    | Fixed chunks -> String.concat "" chunks

  let response_plan req =
    match (String.uppercase_ascii req.Request.method_, req.uri) with
    | "GET", "/small" ->
        {
          status = 200;
          headers = [ ("content-type", "text/plain") ];
          chunks = [ "small" ];
          trailers = [ ("x-demo-trailer", "small-done") ];
          delay_per_chunk = None;
        }
    | "POST", "/echo" ->
        {
          status = 200;
          headers = [ ("content-type", "text/plain") ];
          chunks = [ "echo:"; body_text req ];
          trailers = [ ("x-demo-trailer", "echo-done") ];
          delay_per_chunk = None;
        }
    | "GET", "/stream" ->
        {
          status = 200;
          headers = [ ("content-type", "text/plain") ];
          chunks = [ "part-1"; "part-2"; "part-3" ];
          trailers = [ ("x-demo-trailer", "stream-done") ];
          delay_per_chunk = None;
        }
    | "GET", "/slow" ->
        {
          status = 200;
          headers = [ ("content-type", "text/plain") ];
          chunks = [ "slow-1"; "slow-2" ];
          trailers = [ ("x-demo-trailer", "slow-done") ];
          delay_per_chunk = Some (Duration.ms 50);
        }
    | _ ->
        {
          status = 404;
          headers = [ ("content-type", "text/plain") ];
          chunks = [ "missing" ];
          trailers = [];
          delay_per_chunk = None;
        }

  let error protocol req kind =
    let protocol = match protocol with H1 -> Error.H1 | H2 -> Error.H2 in
    Error.make ~protocol ~method_:req.Request.method_ ~uri:req.uri kind
end
