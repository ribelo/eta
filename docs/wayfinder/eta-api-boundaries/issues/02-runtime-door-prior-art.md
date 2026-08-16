# Runtime-door prior art

Type: research
Status: claimed
Blocked by:

## Question

How do ZIO and effect-ts shape runtime entry points and boundary error
rendering? Cover each library:

- App-facing entry points: how an application hands its main effect to the
  runtime. Give exact public API names and the modules that define them.
- Runtime lifecycle and sharing: one runtime per application, or many?
  Custom runtimes? The documented cost of runtime-per-call, and whether the
  docs endorse or warn against it.
- Boundary error rendering: what the door prints on typed failure, on
  defect, and on interruption.
- Exit codes and interrupt handling at the door.

Sources are primary only: `.reference/zio` and `.reference/effect-smol`.
Cite file paths and lines for every claim.

Write one cited report under `.scratch/research/eta-api-boundaries/`.
