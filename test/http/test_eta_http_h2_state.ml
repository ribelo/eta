open Test_eta_http_support

let h2_permit label = function
  | Ok permit -> permit
  | Error () -> Alcotest.failf "%s rejected unexpectedly" label

let test_h2_admission_counts_cancelled_until_release () =
  let admission = Eta_http.H2.Admission.create ~max_concurrent:2 in
  let first = h2_permit "first" (Eta_http.H2.Admission.try_acquire admission) in
  let second = h2_permit "second" (Eta_http.H2.Admission.try_acquire admission) in
  Alcotest.(check int) "first stream id" 1
    (Eta_http.H2.Admission.stream_id first);
  Alcotest.(check int) "second stream id" 3
    (Eta_http.H2.Admission.stream_id second);
  (match Eta_http.H2.Admission.try_acquire admission with
  | Ok _ -> Alcotest.fail "third stream should be rejected at limit"
  | Error () -> ());
  Eta_http.H2.Admission.mark_remote_reset admission first;
  let reset_stats = Eta_http.H2.Admission.stats admission in
  Alcotest.(check int) "active after remote reset" 1 reset_stats.active;
  Alcotest.(check int) "cancelled after remote reset" 1 reset_stats.cancelled;
  Alcotest.(check int) "cancelled counts as inflight" 2 reset_stats.inflight;
  (match Eta_http.H2.Admission.try_acquire admission with
  | Ok _ -> Alcotest.fail "cancelled stream should still occupy admission"
  | Error () -> ());
  Alcotest.(check bool) "remote reset release does not queue RST" true
    (Eta_http.H2.Admission.release admission first = Eta_http.H2.Admission.No_rst);
  let third = h2_permit "third" (Eta_http.H2.Admission.try_acquire admission) in
  Alcotest.(check int) "third stream id" 5
    (Eta_http.H2.Admission.stream_id third);
  Alcotest.(check bool) "active release queues RST" true
    (Eta_http.H2.Admission.release admission second = Eta_http.H2.Admission.Queue_rst);
  Alcotest.(check bool) "release is idempotent" true
    (Eta_http.H2.Admission.release admission second = Eta_http.H2.Admission.No_rst);
  Alcotest.(check bool) "third active release queues RST" true
    (Eta_http.H2.Admission.release admission third = Eta_http.H2.Admission.Queue_rst);
  let stats = Eta_http.H2.Admission.stats admission in
  Alcotest.(check int) "active final" 0 stats.active;
  Alcotest.(check int) "cancelled final" 0 stats.cancelled;
  Alcotest.(check int) "opened" 3 stats.opened;
  Alcotest.(check int) "completed" 3 stats.completed;
  Alcotest.(check int) "local resets" 2 stats.local_resets;
  Alcotest.(check int) "remote resets" 1 stats.remote_resets;
  Alcotest.(check int) "rejected" 2 stats.admission_rejected;
  Alcotest.(check int) "max inflight" 2 stats.max_inflight

let h2_stream label = function
  | Ok stream -> stream
  | Error () -> Alcotest.failf "%s rejected unexpectedly" label

let test_h2_stream_state_release_decisions () =
  let state = Eta_http.H2.Stream_state.create ~max_concurrent:2 in
  let first =
    h2_stream "first" (Eta_http.H2.Stream_state.open_stream state ~tag:11)
  in
  let second =
    h2_stream "second" (Eta_http.H2.Stream_state.open_stream state ~tag:12)
  in
  Alcotest.(check bool) "server stream id rejected" false
    (Eta_http.H2.Stream_state.is_client_stream_id 2);
  Alcotest.(check int) "first stream id" 1
    (Eta_http.H2.Stream_state.id first);
  Alcotest.(check bool) "first client stream id" true
    (Eta_http.H2.Stream_state.is_client_stream_id
       (Eta_http.H2.Stream_state.id first));
  Alcotest.(check int) "second stream id" 3
    (Eta_http.H2.Stream_state.id second);
  Alcotest.(check int) "tag" 11 (Eta_http.H2.Stream_state.tag first);
  (match Eta_http.H2.Stream_state.open_stream state ~tag:13 with
  | Ok _ -> Alcotest.fail "third stream should be rejected at limit"
  | Error () -> ());
  Eta_http.H2.Stream_state.mark_remote_reset state
    (Eta_http.H2.Stream_state.id first);
  Alcotest.(check bool) "first remote reset" true
    (Eta_http.H2.Stream_state.status first
    = Eta_http.H2.Stream_state.Remote_reset);
  let reset_stats = Eta_http.H2.Stream_state.stats state in
  Alcotest.(check int) "active after reset" 1 reset_stats.active;
  Alcotest.(check int) "cancelled after reset" 1 reset_stats.cancelled;
  Alcotest.(check int) "cancelled still inflight" 2 reset_stats.inflight;
  Alcotest.(check int) "live after reset" 2 reset_stats.live;
  (match Eta_http.H2.Stream_state.open_stream state ~tag:14 with
  | Ok _ -> Alcotest.fail "cancelled stream should still occupy admission"
  | Error () -> ());
  Alcotest.(check bool) "remote reset release does not queue RST" true
    (Eta_http.H2.Stream_state.release state first
    = Eta_http.H2.Stream_state.No_rst);
  Alcotest.(check bool) "release idempotent" true
    (Eta_http.H2.Stream_state.release state first
    = Eta_http.H2.Stream_state.No_rst);
  let third =
    h2_stream "third" (Eta_http.H2.Stream_state.open_stream state ~tag:13)
  in
  Alcotest.(check int) "third stream id" 5
    (Eta_http.H2.Stream_state.id third);
  Eta_http.H2.Stream_state.mark_complete state second;
  Alcotest.(check bool) "second complete" true
    (Eta_http.H2.Stream_state.status second = Eta_http.H2.Stream_state.Complete);
  Alcotest.(check bool) "complete release does not queue RST" true
    (Eta_http.H2.Stream_state.release state second
    = Eta_http.H2.Stream_state.No_rst);
  Alcotest.(check bool) "active release queues RST" true
    (Eta_http.H2.Stream_state.release state third
    = Eta_http.H2.Stream_state.Queue_rst);
  let stats = Eta_http.H2.Stream_state.stats state in
  Alcotest.(check int) "active final" 0 stats.active;
  Alcotest.(check int) "cancelled final" 0 stats.cancelled;
  Alcotest.(check int) "live final" 0 stats.live;
  Alcotest.(check int) "opened" 3 stats.opened;
  Alcotest.(check int) "completed" 3 stats.completed;
  Alcotest.(check int) "local resets" 1 stats.local_resets;
  Alcotest.(check int) "remote resets" 1 stats.remote_resets;
  Alcotest.(check int) "rejected" 2 stats.admission_rejected;
  Alcotest.(check int) "max inflight" 2 stats.max_inflight

let test_h2_stream_state_close_releases_live_state () =
  let state = Eta_http.H2.Stream_state.create ~max_concurrent:2 in
  let first =
    h2_stream "first" (Eta_http.H2.Stream_state.open_stream state ~tag:1)
  in
  let second =
    h2_stream "second" (Eta_http.H2.Stream_state.open_stream state ~tag:2)
  in
  Eta_http.H2.Stream_state.mark_remote_reset state
    (Eta_http.H2.Stream_state.id first);
  Eta_http.H2.Stream_state.close state;
  Alcotest.(check bool) "first released" true
    (Eta_http.H2.Stream_state.status first = Eta_http.H2.Stream_state.Released);
  Alcotest.(check bool) "second released" true
    (Eta_http.H2.Stream_state.status second = Eta_http.H2.Stream_state.Released);
  (match Eta_http.H2.Stream_state.open_stream state ~tag:3 with
  | Ok _ -> Alcotest.fail "closed state should reject new streams"
  | Error () -> ());
  let stats = Eta_http.H2.Stream_state.stats state in
  Alcotest.(check int) "active closed" 0 stats.active;
  Alcotest.(check int) "cancelled closed" 0 stats.cancelled;
  Alcotest.(check int) "live closed" 0 stats.live

