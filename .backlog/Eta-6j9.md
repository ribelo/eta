---
id: Eta-6j9
title: "Epic: Code review remediation — structural and bug findings"
status: closed
priority: 1
issue_type: epic
created_at: 2026-05-24T09:43:10.933Z
created_by: backlog
updated_at: 2026-05-24T11:47:49Z
closed_at: 2026-05-24T11:47:49Z
close_reason: "All remediation child tasks listed in .objectives/code-review-remediation.md are closed; RED-test tasks shipped fixes, structural refactors landed, and nix develop -c dune runtest --force passes."
---

# Epic: Code review remediation — structural and bug findings

## description

Umbrella for findings from two code review passes. Each child task is independently grabbable; closing them is the unit of progress. Two distinct kinds of work live here:

1. Behavioral bug fixes (P0/P1/P2 from the first review). Each starts with a RED test that fails on current code and passes after the fix. Twenty tasks created flat in the previous session: Eta-oj1, Eta-1lf, Eta-asf, Eta-3k8, Eta-89b, Eta-u1f, Eta-9jk, Eta-k2y, Eta-18b, Eta-8wp, Eta-jgf, Eta-bl0, Eta-zfn, Eta-44a, Eta-913, Eta-0m2, Eta-cpl, Eta-li4, Eta-onp, Eta-18v.

2. Structural refactors (this review pass). Behavior-preserving; the existing test suite passing pre- and post-refactor is the regression gate. No new RED tests.

The epic exists for visibility and to make the review-derived backlog easy to find. Children are not mutually blocked; close in any order.

## acceptance criteria

All children closed. The bug-fix children have shipped their RED tests and fixes. The refactor children have landed their structural changes with the full test suite passing pre and post.
