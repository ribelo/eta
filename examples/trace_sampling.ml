open Eta

let sample sampler ~trace_id ~name ~parent =
  Sampler.sample sampler ~trace_id ~name
    ~attrs:[ ("route", "/users/:id") ]
    ~parent

let () =
  let ratio = Sampler.ratio 0.5 in
  let first = sample ratio ~trace_id:"trace-a" ~name:"request" ~parent:false in
  let same_trace_different_span =
    sample ratio ~trace_id:"trace-a" ~name:"request.child" ~parent:false
  in
  let all_on =
    sample (Sampler.ratio 2.0) ~trace_id:"trace-b" ~name:"request"
      ~parent:false
  in
  let all_off =
    sample (Sampler.ratio (-1.0)) ~trace_id:"trace-c" ~name:"request"
      ~parent:false
  in
  let parent_based = Sampler.parent_based ~root:Sampler.always_off () in
  let root =
    sample parent_based ~trace_id:"trace-d" ~name:"root" ~parent:false
  in
  let child =
    sample parent_based ~trace_id:"trace-d" ~name:"child" ~parent:true
  in
  let same_trace_stable = Bool.equal first same_trace_different_span in
  if same_trace_stable && all_on && (not all_off) && (not root) && child then
    Format.printf
      "sampler:ratio=%b same-trace=%b all-on=%b all-off=%b root=%b child=%b@."
      first same_trace_stable all_on all_off root child
  else (
    Format.eprintf "sampler produced unexpected decisions@.";
    exit 1)
