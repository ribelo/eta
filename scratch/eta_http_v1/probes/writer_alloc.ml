(* Scratch-only R2 allocation probe for the h1 raw byte-buffer writer. *)

let fail msg =
  Printf.eprintf "eta_http_r2_writer_alloc verdict=FAIL detail=%S\n%!" msg;
  exit 1

let iterations = 100_000

let run_once buffer url headers body =
  Eta_http.H1.Write.write_to_bytes_raw buffer ~pos:0 ~method_:"POST" ~url
    ~headers ~body

let rec loop buffer url headers body remaining checksum =
  if remaining = 0 then checksum
  else
    let written = run_once buffer url headers body in
    if written < 0 then fail (Printf.sprintf "writer returned %d" written);
    loop buffer url headers body (remaining - 1) (checksum + written)

let () =
  let url = Eta_http.Core.Url.of_string "https://API.Example.test:8443/v1/echo?mode=alloc" in
  let headers = [ ("Accept", "application/json"); ("X-Test", "r2") ] in
  let body =
    Eta_http.H1.Write.Fixed [ Bytes.of_string "alpha"; Bytes.of_string "beta" ]
  in
  let buffer = Bytes.create 1024 in
  Gc.full_major ();
  let before = (Gc.quick_stat ()).Gc.minor_words in
  let checksum = loop buffer url headers body iterations 0 in
  let after = (Gc.quick_stat ()).Gc.minor_words in
  let minor_words = after -. before in
  let words_per_write = minor_words /. float_of_int iterations in
  let verdict = if minor_words = 0.0 then "PASS" else "FAIL" in
  Printf.printf
    "eta_http_r2_writer_alloc verdict=%s iterations=%d minor_words=%.0f words_per_write=%.6f checksum=%d\n%!"
    verdict iterations minor_words words_per_write checksum;
  if minor_words <> 0.0 then exit 1
