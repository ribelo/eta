(* CVE / adversarial test runner binary. *)

open Eta_http_testsuite

let () =
  let run_id =
    Printf.sprintf "%s-%s"
      (Util.utc_timestamp ())
      (Util.git_sha ())
  in
  let results_dir =
    Filename.concat "http-testsuite/results" run_id
  in
  Util.mkdir_p results_dir;
  let manifest : Types.run_manifest =
    {
      run_id;
      git_sha = Util.git_sha ();
      ocaml_version = Util.version_of_cmd "ocamlc -version";
      nginx_version = Util.version_of_cmd "nginx -v";
      caddy_version = Util.version_of_cmd "caddy version";
      curl_version = Util.version_of_cmd "curl --version";
      nghttp2_version = Util.version_of_cmd "nghttp --version";
      eta_http_sha = Util.git_sha ();
      host = Util.hostname ();
      started_at = Util.utc_timestamp ();
    }
  in
  Json.write_manifest ~path:(Filename.concat results_dir "manifest.json") manifest;
  Printf.printf "cve_runner run_id=%s results_dir=%s\n%!" run_id results_dir;

  Eio_main.run @@ fun env ->
  let cve_results = Adversarial.run_all ~env in
  Json.write_cve ~path:(Filename.concat results_dir "cve.json") cve_results;

  Summary.render
    ~interop_results:[]
    ~cve_results
    ~bench_iterations:[]
    ~manifest
    ~path:(Filename.concat results_dir "summary.md");

  let failed =
    List.exists
      (fun (result : Types.adversarial_result) ->
        (not result.passed) && Option.is_none result.skipped)
      cve_results
  in
  Printf.printf "cve_runner done results_dir=%s\n%!" results_dir;
  if failed then exit 1
