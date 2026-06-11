 (** summary.md renderer. *)

open Types

let render_scenario_result r =
  let status_str =
    match r.status with
    | Pass -> "PASS"
    | Divergent -> "DIVERGENT"
    | Fail -> "FAIL"
    | Skip reason -> "SKIP (" ^ reason ^ ")"
  in
  Printf.sprintf "| %s | %s | %s | %s | %s | %.2f |"
    r.name
    (match r.server with Nginx -> "nginx" | Caddy -> "caddy" | Eta -> "eta")
    (match r.protocol with H1 -> "h1" | H2 -> "h2")
    (match r.transport with Plain -> "plain" | TLS -> "tls")
    status_str
    r.duration_ms

let render ~interop_results ~cve_results ~bench_iterations ~manifest ~path =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       Printf.fprintf oc "# Eta HTTP Testsuite Summary\n\n";
       Printf.fprintf oc "Run ID: %s\n" manifest.run_id;
       Printf.fprintf oc "Git SHA: %s\n" manifest.git_sha;
       Printf.fprintf oc "Started: %s\n\n" manifest.started_at;

       (* Interop counts *)
       let pass = List.filter (fun r -> r.status = Pass) interop_results |> List.length in
       let divergent = List.filter (fun r -> r.status = Divergent) interop_results |> List.length in
       let fail = List.filter (fun r -> r.status = Fail) interop_results |> List.length in
       let skip = List.filter (fun r -> match r.status with Skip _ -> true | _ -> false) interop_results |> List.length in
       Printf.fprintf oc "## Interop Results\n\n";
       Printf.fprintf oc "PASS: %d  DIVERGENT: %d  FAIL: %d  SKIP: %d\n\n" pass divergent fail skip;
       Printf.fprintf oc "| Scenario | Server | Protocol | Transport | Status | Duration (ms) |\n";
       Printf.fprintf oc "|---|---|---|---|---|---|\n";
       List.iter (fun r -> Printf.fprintf oc "%s\n" (render_scenario_result r)) interop_results;
       Printf.fprintf oc "\n";

       (* CVE counts *)
       let cve_pass = List.filter (fun r -> r.passed) cve_results |> List.length in
       let cve_fail = List.length cve_results - cve_pass in
       Printf.fprintf oc "## Adversarial / CVE Results\n\n";
       Printf.fprintf oc "PASS: %d  FAIL: %d\n\n" cve_pass cve_fail;
       List.iter (fun r ->
           Printf.fprintf oc "- %s: %s (peak RSS: %d KB, error: %s)\n"
             r.name
             (if r.passed then "PASS" else "FAIL")
             r.peak_rss_kb
             (Option.value ~default:"none" r.error_variant)
         ) cve_results;
       Printf.fprintf oc "\n";

       (* Bench table *)
       Printf.fprintf oc "## Benchmark Results\n\n";
       Printf.fprintf oc "| Scenario | Client | Count | Mean (ms) | P50 (ms) | P95 (ms) | P99 (ms) |\n";
       Printf.fprintf oc "|---|---|---|---|---|---|---|\n";
       let by_scenario_client =
         let tbl = Hashtbl.create 16 in
         List.iter (fun (iter : bench_iteration) ->
             let key = (iter.scenario, iter.client) in
             Hashtbl.add tbl key iter
           ) bench_iterations;
         tbl
       in
       let keys = Hashtbl.fold (fun k _ acc -> k :: acc) by_scenario_client [] |> List.sort_uniq compare in
       List.iter (fun (scenario, client) ->
           let iters = Hashtbl.find_all by_scenario_client (scenario, client) in
           let times = List.map (fun i -> Int64.to_float i.duration_ns /. 1_000_000.0) iters in
           let sorted = List.sort compare times in
           let count = List.length sorted in
           if count > 0 then
             let mean = List.fold_left ( +. ) 0.0 sorted /. float count in
             let p50 = List.nth sorted (count * 50 / 100) in
             let p95 = List.nth sorted (min (count - 1) (count * 95 / 100)) in
             let p99 = List.nth sorted (min (count - 1) (count * 99 / 100)) in
             Printf.fprintf oc "| %s | %s | %d | %.2f | %.2f | %.2f | %.2f |\n"
               scenario client count mean p50 p95 p99
         ) keys;
       Printf.fprintf oc "\n";
    )
