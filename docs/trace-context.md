# Native W3C trace-context propagation

Firstmate can propagate a W3C [`traceparent`](https://www.w3.org/TR/trace-context/) to every agent it spawns so an external observer can correlate a worker, a Secondmate, and their nested children into one trace.
The capability is default-off, source-owned, vendor-neutral, and deliberately narrow.
This document is the rationale and current-behavior guide; `docs/configuration.md` owns the configuration schema, `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records the repeatable test evidence.

## Why this is a source change at all

Everything else an observer needs is already derivable from Firstmate's durable operational artifacts.
`state/<id>.meta` already carries the task id, backend, harness, model, effort, kind, and mode, and `state/*.status`, `.turn-ended`, and the branch key a spawn already computes let a downstream reconstruct lifecycle without any source change.
The one thing that cannot be derived after the fact is a task-scoped trace id that exists in the agent's environment *before it launches* and is also known to the observer.
`launch_template()` hardcodes per-harness prefixes and the only per-pane export is a hardcoded `GOTMPDIR`, so there is no seam for it.
This increment adds exactly that seam and nothing more.

## What it does

When enabled, for each spawn Firstmate resolves one W3C `traceparent` carrier for the task - minted on the first spawn, inherited as a child (fresh span, same trace) for a nested spawn, and reused verbatim from the meta on relaunch - and:

- forms it as `00-<32 hex trace id>-<16 hex span id>-<2 hex flags>`, with random ids for a new root;
- injects it into the agent's pane shell as the `TRACEPARENT` environment variable immediately before launch, through the same `spawn_send_text_line` channel that already ships `GOTMPDIR`; and
- records the identical value as `traceparent=` in `state/<id>.meta`.

`TRACEPARENT` as an environment variable is a Firstmate convention carrying a W3C-formatted value: W3C Trace Context standardizes the `traceparent` HTTP header, not an env var, and OpenTelemetry SDKs do not read it from the environment automatically, so a downstream observer must explicitly read this env value or the `traceparent=` meta field. This feature parents no SDK span by itself.

Because the injected carrier and the recorded carrier are the same string, an observer that reads the metadata reconstructs exactly the identity the child received.
The injection sits at the unconditional pre-launch export site, so it covers ship, scout, and Secondmate spawns and is identical across every harness (`claude`, `codex`, `opencode`, `pi`, `grok`) - the same coverage `GOTMPDIR` already has, with no `launch_template()` change.
Ship and scout spawns reach that site on every spawn backend (`tmux`, `herdr`, `zellij`, `orca`, `cmux`); a Secondmate reaches it on every backend that accepts a Secondmate spawn (`tmux`, `herdr`, `zellij`), because `bin/fm-spawn.sh` rejects a Secondmate on `orca` and `cmux`.

## Root, child, and recovery semantics

The point of these rules is to never mint an unrelated root by accident.

- **Root** - a spawn with no valid inherited `TRACEPARENT` mints a fresh trace id, a fresh span id, and sampled flags (`01`). This begins a new trace, one per top-level task.
- **Child** - a spawn whose own Firstmate process already holds a valid `TRACEPARENT` in its environment keeps that trace id and its flags while minting a fresh span id. This is what makes a nested Firstmate -> Secondmate -> worker chain share one trace: a Secondmate is itself a spawned agent, so when it was launched with trace context enabled it received a `TRACEPARENT`, and it passes that trace on to its own workers.
- **Recovery** - a valid `traceparent=` already recorded in the task's meta is reused verbatim, so a relaunched or recovered task keeps one stable identity across restarts rather than starting a second trace.

A malformed or all-zero inherited value is treated as absent, so garbage never propagates and the spawn roots a clean trace instead (it is not omitted).

### Enablement takes effect at the next launch, not retroactively

Trace context is read from a process's environment, which is fixed when that process starts, so enabling the capability affects only agents spawned *after* enablement:

- The primary propagates `config/trace-context` into Secondmate homes (it is in `FM_INHERITABLE_CONFIG`), and `bin/fm-config-push.sh` can push it to already-running homes, but copying the flag into a live Secondmate home does **not** retroactively set that already-running Secondmate process's ambient `TRACEPARENT`.
- A Secondmate **launched or relaunched after** enablement is spawned by the primary with the primary's `TRACEPARENT` and the primary's effective on/off decision (delivered as `FM_TRACE_CONTEXT` in the launch prefix by `bin/fm-spawn.sh`) in its environment, so the primary's enable/disable state governs that Secondmate's own workers both ways.
  An enabled primary preserves one connected trace into them, while `FM_TRACE_CONTEXT=off` on the primary keeps them untraced even when the `config/trace-context` file was copied into the Secondmate home - a real fleet-level kill switch, not only a per-home file toggle.
- An **already-running** Secondmate has no ambient `TRACEPARENT`, so its subsequent workers start their own new root traces - still valid, just not joined to the primary's trace - until that Secondmate is relaunched.

So enabling trace context mid-session does not instantly weave every in-flight agent into one tree; it applies from each agent's next launch. Firstmate deliberately does not restart or re-environment a running agent to hide this, which would be disruptive lifecycle control the observer does not need.

## Sampling

A new root sets the W3C trace flags to `01` (sampled). This is a deliberate, source-owned choice:

- The capability is **opt-in** and default-off, so a home that enables it is asking for its spawns to be traced; an unsampled (`00`) root would produce a trace id that most downstream parent-based samplers drop, yielding nothing for the operator who opted in.
- **Inherited flags are preserved unchanged.** A child adopts the parent's flags verbatim, so an unsampled (`00`) parent keeps its whole subtree unsampled and an upstream sampler's decision is honored end to end. Firstmate chooses the flag only when it mints a *root*; it never overrides an inherited decision.
- **Cost and privacy consequence.** `01` records a sampling *decision*, and a conforming downstream parent-based sampler will honor it - but it does not by itself guarantee that any collector stores a span, and Firstmate emits no spans of its own; it only sets the flag on the carrier. An operator who enables the capability and points sampling-respecting instrumentation at it should expect on the order of one trace per top-level task plus its nested spans to be recorded, at whatever cardinality and retention that instrumentation is configured for. An operator who wants unsampled roots or head-sampling owns that downstream or via a later, explicitly-scoped option; Firstmate does not embed a sampler.

## Safety

- **Default-off.** With no `config/trace-context` and no `FM_TRACE_CONTEXT`, nothing is injected and no `traceparent=` line is written, so the generated meta and the launch environment are unchanged. The spawn does source one extra library and make one config-file check, both of which resolve to a no-op, so it is not literally byte-for-byte identical as a process, but nothing an agent, an observer, or the meta can see differs.
- **What is and is not exposed.** A Firstmate-*minted* root uses a random id and reads no prompt, path, task prose, credential, or arbitrary environment key, so Firstmate never *originates* sensitive data in the carrier. An *inherited* `TRACEPARENT` is opaque caller-controlled data: its 16-byte trace id and 8-byte span id are up to 24 bytes (48 hex chars) that Firstmate passes through after syntax validation without interpreting, so whoever set `TRACEPARENT` in Firstmate's environment (a trusted local operator or observer) controls those bytes. Exposure is bounded to that fixed-width carrier - it cannot carry a `tracestate`, an `OTEL_*` credential variable, or any arbitrary environment key, and there is no configurable or arbitrary command (only the fixed local `od`/`tr` for entropy) - but the id bytes are not 'structurally impossible to carry data'.
- **Fail-independent.** Minting is a small local entropy pipeline: it reads a few bytes from `/dev/urandom` through the fixed local `od` and `tr` (resolved from PATH). There is no configured provider command, no network, and no watchdog. The normal cost is small, but `od`/`tr` are external processes, so there is no hard latency guarantee - this is not a guaranteed-negligible bound. Any entropy or self-validation failure that returns omits the carrier for that spawn without aborting source work; a malformed or all-zero inherited value is treated as absent and roots a fresh trace (it is not an omission).
- **Metadata-only.** The value lives in the ephemeral pane shell and in `state/<id>.meta`; teardown removes state as before, so there is no new durable surface and no schema migration.

## Relationship to OpenTelemetry and later increments

Firstmate learns nothing about OpenTelemetry, any exporter, collector, storage, or UI.
It emits a standard W3C carrier and records the same identity; a downstream observer owns everything else and discovers the capability from the presence of `config/trace-context` and the `traceparent=` field.
Native lifecycle-event emission, extra stable IDs, intake metadata, and any embedded OTLP are deliberately deferred until a running observer demonstrates a concrete fidelity gap that the derived artifacts cannot cover.

## Verification

Repeatable test evidence - the unit and spawn-path suites with exact commands and output - lives in [`verification/trace-context.md`](verification/trace-context.md).
