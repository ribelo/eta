---
kind: requirement
---
# Supervisor request cancellation

## Intent

Give supervised callers one stable point after a child cancellation request and
before child settlement. Keep request ordering separate from cleanup, result
observation, and the structured ownership fence. Callers retain admission policy.

## Requirements

- The root `eta` package shall expose `Supervisor.Scope.request_cancel` with type `('s, 'err, 'a) child -> ('s, unit, 'outer_err) Scope.t`. ^supcan-iar6
- When a scope program invokes `request_cancel`, the supervisor shall latch the child cancellation request before the operation returns. ^supcan-stst
- When a scope program invokes `request_cancel`, the supervisor shall return without waiting for child settlement or finalizers. ^supcan-f3ww
- When a cancellation request is latched before a child installs its runtime contexts, the supervisor shall prevent the child body from starting. ^supcan-zqzf
- When a caller invokes `request_cancel` repeatedly for one child, the supervisor shall use one cancellation path and run child finalizers at most once. ^supcan-l1iy
- If a caller invokes `request_cancel` after a child settles, then the supervisor shall keep the child terminal outcome unchanged. ^supcan-3os1
- When child completion, failure, and cancellation race, the supervisor shall keep the first terminal publication. ^supcan-glb2
- When a caller invokes `cancel` after `request_cancel`, the supervisor shall wait for child settlement and finalizers. ^supcan-3sp7
- When pure interruption settles a requested child, `cancel` shall return successful cancellation acknowledgement. ^supcan-dyvd
- When a requested child settles with a typed failure, defect, or finalizer diagnostic, `cancel` shall preserve the complete `Eta.Cause`. ^supcan-nnq7
- When a caller invokes `await` after `request_cancel`, the supervisor shall return the ordinary child outcome, including interruption when cancellation wins. ^supcan-eg0p
- When one scope program invokes several request operations, the supervisor shall latch their request points in scope-program order. ^supcan-6zw9
- The Eta scheduler shall determine interruption observation and finalizer order for different requested children independently of request-point order. ^supcan-urkv
- When `Supervisor.scoped` exits after cancellation requests, the supervisor shall settle every owned child and finalizer before returning. ^supcan-5oxj
- The `request_cancel` operation shall return `unit` without adding a typed failure to the surrounding scope. ^supcan-tg7n
- The supervisor request-cancellation API shall keep child handles rank-two scoped and keep runtime scopes, cancellation contexts, and detach operations private. ^supcan-qbzk
- When `Runtime_contract.cancel` receives a cancellation request, the backend shall record the request and return without waiting for target settlement. ^supcan-kptd
- When `Runtime_contract.fail_scope` receives a failure, the backend shall record the failure, request cancellation, and return without waiting for scope settlement. ^supcan-0uj5
- Where an Eta runtime backend supports supervisors, `request_cancel` shall provide the same observable contract on native Eio and JavaScript runtimes. ^supcan-yncg
- The supervisor request-cancellation API shall retain the runtime contract owner-domain restriction. ^supcan-xhxq
- When a caller releases registered work after every cancellation request returns, the supervisor shall permit the released work to overlap unsettled cleanup. ^supcan-vb4t
