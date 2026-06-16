type wildcard = {
  start : int;
  end_ : int;
}

type remapping = string list

let invalid_route msg = Error (Router_error.Invalid_route msg)

let find_wildcard (path : Escape.slice) :
    (wildcard option, Router_error.insert) result =
  let len = Escape.slice_length path in
  let mutable i = 0 in
  let mutable start = -1 in
  let mutable error = None in
  while i < len && start < 0 && error = None do
    let c = Escape.slice_unsafe_get path i in
    if c = '}' && not (Escape.slice_is_escaped path i) then
      error <- Some "unmatched closing brace"
    else if c = '{' && not (Escape.slice_is_escaped path i) then
      start <- i
    else
      i <- i + 1
  done;
  match error with
  | Some msg -> invalid_route msg
  | None ->
    if start < 0 then Ok None
    else if start + 1 >= len then invalid_route "unterminated parameter"
    else if Escape.slice_unsafe_get path (start + 1) = '}' then
      invalid_route "empty parameter name"
    else
      let mutable i = start + 2 in
      let mutable end_ = -1 in
      let mutable error = None in
      while i < len && end_ < 0 && error = None do
        let c = Escape.slice_unsafe_get path i in
        match c with
        | '}' ->
          if Escape.slice_is_escaped path i then
            i <- i + 1
          else if Escape.slice_unsafe_get path (i - 1) = '*' then
            error <- Some "parameter name ends with *"
          else
            end_ <- i + 1
        | '*' | '/' -> error <- Some "invalid character in parameter name"
        | _ -> i <- i + 1
      done;
      match error with
      | Some msg -> invalid_route msg
      | None ->
        if end_ < 0 then invalid_route "unterminated parameter"
        else Ok (Some { start; end_ })

let is_catch_all bytes w =
  String.unsafe_get bytes (w.start + 1) = '*'

let normalize (route : Escape.t) :
    (Escape.t * remapping, Router_error.insert) result =
  let bytes = Escape.to_string route in
  let len = String.length bytes in
  (* The normalized route is never longer than the original. *)
  let buf = Bytes.create len in
  let esc = Bytes.make len '\000' in
  let src = ref 0 in
  let dst = ref 0 in
  let remapping = ref [] in
  let next_char = ref 'a' in

  let copy from_len =
    for i = 0 to from_len - 1 do
      Bytes.unsafe_set buf (!dst + i) (String.unsafe_get bytes (!src + i));
      if Escape.is_escaped route (!src + i) then
        Bytes.unsafe_set esc (!dst + i) '\001'
    done;
    src := !src + from_len;
    dst := !dst + from_len
  in

  let write bytes_to_write =
    List.iteri
      (fun i c -> Bytes.unsafe_set buf (!dst + i) c)
      bytes_to_write;
    dst := !dst + List.length bytes_to_write
  in

  let rec loop () =
    if !src >= len then Ok ()
    else
      match
        find_wildcard
          (Escape.slice (Escape.full route) ~off:!src ~len:(len - !src))
      with
      | Error _ as e -> e
      | Ok None ->
          copy (len - !src);
          Ok ()
      | Ok (Some w) -> (
          let w_start = !src + w.start in
          let w_end = !src + w.end_ in
          copy (w_start - !src);
          let name_len = w_end - w_start - 2 in
          let name = String.sub bytes (w_start + 1) name_len in
          if is_catch_all bytes { start = w_start; end_ = w_end } then (
            for i = 0 to w_end - w_start - 1 do
              Bytes.unsafe_set buf (!dst + i)
                (String.unsafe_get bytes (w_start + i));
              if Escape.is_escaped route (w_start + i) then
                Bytes.unsafe_set esc (!dst + i) '\001'
            done;
            src := w_end;
            dst := !dst + (w_end - w_start);
            loop ())
          else (
            write [ '{'; !next_char; '}' ];
            remapping := name :: !remapping;
            next_char := Char.chr (Char.code !next_char + 1);
            src := w_end;
            loop ()))
  in
  match loop () with
  | Error _ as e -> e
  | Ok () ->
      let normalized =
        Escape.make_unescaped ~bytes:(Bytes.sub_string buf 0 !dst) ~escaped:(Bytes.sub_string esc 0 !dst)
      in
      Ok (normalized, List.rev !remapping)

let denormalize (route : Escape.t) (remapping : remapping) : Escape.t =
  let bytes = Escape.to_string route in
  let len = String.length bytes in
  let max_len = len + List.fold_left (fun acc s -> acc + String.length s) 0 remapping in
  let buf = Bytes.create max_len in
  let esc = Bytes.make max_len '\000' in
  let src = ref 0 in
  let dst = ref 0 in
  let remapping = ref remapping in

  let copy from_len =
    for i = 0 to from_len - 1 do
      Bytes.unsafe_set buf (!dst + i) (String.unsafe_get bytes (!src + i));
      if Escape.is_escaped route (!src + i) then
        Bytes.unsafe_set esc (!dst + i) '\001'
    done;
    src := !src + from_len;
    dst := !dst + from_len
  in

  let rec loop () =
    if !src >= len then ()
    else
      match
        find_wildcard
          (Escape.slice (Escape.full route) ~off:!src ~len:(len - !src))
      with
      | Ok (Some w) -> (
          let w_start = !src + w.start in
          let w_end = !src + w.end_ in
          copy (w_start - !src);
          let name =
            match !remapping with
            | [] ->
                (* No remapping entry; keep the normalized parameter name. *)
                let name_len = w_end - w_start - 2 in
                String.sub bytes (w_start + 1) name_len
            | name :: rest ->
                remapping := rest;
                name
          in
          Bytes.unsafe_set buf !dst '{';
          for i = 0 to String.length name - 1 do
            Bytes.unsafe_set buf (!dst + 1 + i) name.[i]
          done;
          Bytes.unsafe_set buf (!dst + 1 + String.length name) '}';
          dst := !dst + 2 + String.length name;
          src := w_end;
          loop ())
      | _ -> copy (len - !src)
  in
  loop ();
  Escape.make_unescaped ~bytes:(Bytes.sub_string buf 0 !dst) ~escaped:(Bytes.sub_string esc 0 !dst)
