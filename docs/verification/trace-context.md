# Trace-context propagation verification

Repeatable evidence for the default-off native W3C trace-context capability.
Current behavior and rationale are owned by [`../trace-context.md`](../trace-context.md) and the configuration schema by [`../configuration.md`](../configuration.md) ("Trace context propagation"); this page records evidence only.

Date: 2026-07-24.
Shell: GNU bash 3.2.57 (macOS).
Base: `origin/main` at `861b1f8`.

The colocated unit suite `tests/fm-trace-context-lib.test.sh` (26 assertions) exercises validation (valid accepted; malformed, wrong-length, uppercase, all-zero, `ff` version, and shell-metacharacter values rejected), root and child minting, sampled/unsampled flag inheritance, malformed and all-zero inheritance falling back to a root, the recovery reuse path, default-off omission, the enable precedence of `FM_TRACE_CONTEXT` over `config/trace-context` with unset or empty deferring to the file, the Secondmate launch-snapshot boundary with later file state, forced entropy failure omitting safely, the minted-root fixed-shape check, and the opaque-inheritance trust-boundary assertion (an inherited id passes through verbatim as caller-controlled data).

The spawn-path integration suite `tests/fm-trace-context-spawn.test.sh` (7 assertions), hermetic against an ambient `FM_TRACE_CONTEXT`, drives `bin/fm-spawn.sh` end to end with a fake tmux pane and a real isolated git worktree: enabled, one resolved carrier is recorded as `traceparent=` in the meta and the identical `TRACEPARENT` export is sent before the launch literal; disabled, neither is written nor sent (only `GOTMPDIR` is); a relaunch reuses the recorded carrier verbatim; and an explicit `FM_TRACE_CONTEXT` overrides the file both ways (off disables a file-enabled home, on enables a fileless home).
Two further assertions drive a genuine two-level primary -> Secondmate -> worker chain, running `bin/fm-spawn.sh` twice with the exact environment the primary injects into the Secondmate, and prove the primary's effective override governs the nested worker both ways: env-on with no config file keeps the nested worker in the primary's trace, and env-off with the file present keeps the nested worker disabled even though the `config/trace-context` file was copied into the Secondmate home.
A final assertion drives the file-decided path (`FM_TRACE_CONTEXT` unset) and proves the Secondmate's recorded/injected carrier and its delivered `FM_TRACE_CONTEXT=on|off` snapshot are always derived from one frozen decision, so a carrier is never paired with the opposite enable state.
The suite touches no real harness or live fleet.

```console
$ bash tests/fm-trace-context-lib.test.sh | tail -1
# fm-trace-context-lib.test.sh: all assertions passed
$ bash tests/fm-trace-context-spawn.test.sh | tail -1
# all fm-trace-context-spawn tests passed
$ bash bin/fm-lint.sh ; echo $?
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
0
```

Run all three from the repo root; each suite prints one `ok - ...` per assertion and `fm-lint.sh` exits `0` with the pinned ShellCheck.
A single live-backend end-to-end check - a real spawn confirming the pane received the `TRACEPARENT` export before the launch line, with nothing left after teardown - is a bounded manual step, deferred here because a live agent spawn disrupts a running fleet.
