#!/usr/bin/env bash
# tests/fm-trace-context-lib.test.sh - unit tests for the native, default-off
# W3C trace-context library (bin/fm-trace-context-lib.sh) plus structural checks
# that bin/fm-spawn.sh wires it in at the pre-launch injection seam and that the
# capability is inherited into secondmate homes. Pure functions, no backend and
# no live spawn required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

VALID='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'

# --- strict W3C validation ---------------------------------------------------

fm_trace_context_valid "$VALID" || fail "a conformant traceparent must validate"
pass "fm_trace_context_valid accepts a conformant W3C traceparent"

for bad in \
  '00-00000000000000000000000000000000-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01' \
  'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  '00-4BF92F3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01; rm -rf /' \
  '' ; do
  if fm_trace_context_valid "$bad"; then
    fail "invalid traceparent wrongly accepted: '$bad'"
  fi
done
pass "fm_trace_context_valid rejects all-zero ids, ff version, uppercase, wrong length, missing field, shell metacharacters, and empty"

# A value shaped like a command substitution must be rejected as inert data and
# never executed. Assemble it so the test itself never runs it.
dollar='$'
fm_trace_context_valid "${dollar}(touch pwned-$$)" && fail "command-substitution-shaped value wrongly accepted"
[ ! -e "pwned-$$" ] || fail "validation must never execute an injected value"
pass "a command-substitution-shaped value is rejected as inert data, never executed"

# --- entropy source: exact length, hex-only, fresh each call -----------------

t=$(fm_trace_context_hex 16)
[ "${#t}" -eq 32 ] || fail "16-byte hex must be 32 chars, got ${#t}"
case "$t" in *[!0-9a-f]*) fail "trace hex is not lowercase hex: $t" ;; esac
s=$(fm_trace_context_hex 8)
[ "${#s}" -eq 16 ] || fail "8-byte hex must be 16 chars, got ${#s}"
[ "$(fm_trace_context_hex 8)" != "$(fm_trace_context_hex 8)" ] || fail "hex must be fresh per call"
pass "fm_trace_context_hex yields exact-length lowercase hex, distinct per call"

# --- root mint ---------------------------------------------------------------

ROOT_TP=$(fm_trace_context_mint "")
fm_trace_context_valid "$ROOT_TP" || fail "root mint must be a valid traceparent: $ROOT_TP"
[ "${ROOT_TP:53:2}" = "01" ] || fail "root mint must default to sampled flags 01: $ROOT_TP"
[ "${ROOT_TP:3:32}" != "00000000000000000000000000000000" ] || fail "root trace id must be non-zero"
pass "fm_trace_context_mint with no parent starts a valid sampled root trace"

# --- child mint inherits trace id + flags, mints a fresh span ----------------

PARENT='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00'
CHILD=$(fm_trace_context_mint "$PARENT")
fm_trace_context_valid "$CHILD" || fail "child mint must be valid: $CHILD"
[ "${CHILD:3:32}" = "${PARENT:3:32}" ] || fail "child must inherit the parent trace id"
[ "${CHILD:53:2}" = "${PARENT:53:2}" ] || fail "child must inherit the parent flags (00)"
[ "${CHILD:36:16}" != "${PARENT:36:16}" ] || fail "child must mint a fresh span id"
pass "fm_trace_context_mint adopts a valid parent's trace id and flags with a fresh span id"

# --- sampling flags: root is sampled 01; a child preserves the parent flag -----

sroot=$(fm_trace_context_mint "")
[ "${sroot:53:2}" = "01" ] || fail "a minted root must be sampled (01): $sroot"
sampled_child=$(fm_trace_context_mint '00-33333333333333333333333333333333-4444444444444444-01')
[ "${sampled_child:53:2}" = "01" ] || fail "a child of a sampled (01) parent must stay sampled: $sampled_child"
unsampled_child=$(fm_trace_context_mint '00-33333333333333333333333333333333-4444444444444444-00')
[ "${unsampled_child:53:2}" = "00" ] || fail "a child of an unsampled (00) parent must stay unsampled: $unsampled_child"
[ "${sampled_child:3:32}" = "33333333333333333333333333333333" ] || fail "a child must keep the parent trace id regardless of flags"
pass "a root is sampled (01) by decision; a child preserves the parent's sampled/unsampled flag verbatim, never overriding it"

# --- nested Firstmate -> Secondmate -> worker share one trace id -------------

L1=$(fm_trace_context_mint "")        # primary spawns a secondmate
L2=$(fm_trace_context_mint "$L1")     # secondmate spawns a worker
L3=$(fm_trace_context_mint "$L2")     # a further nested spawn
[ "${L1:3:32}" = "${L2:3:32}" ] && [ "${L2:3:32}" = "${L3:3:32}" ] \
  || fail "nested chain must share one trace id"
[ "${L1:36:16}" != "${L2:36:16}" ] && [ "${L2:36:16}" != "${L3:36:16}" ] && [ "${L1:36:16}" != "${L3:36:16}" ] \
  || fail "nested chain must have distinct span ids"
pass "nested Firstmate -> Secondmate -> worker mints share one trace id with distinct span ids"

# --- malformed / all-zero inherited context roots a clean trace --------------

for garbage in 'not-a-traceparent' '00-00000000000000000000000000000000-0000000000000000-01' '' ; do
  fresh=$(fm_trace_context_mint "$garbage")
  fm_trace_context_valid "$fresh" || fail "malformed/all-zero inherited must fall back to a valid root: '$garbage' -> '$fresh'"
  [ "${fresh:3:32}" != "00000000000000000000000000000000" ] || fail "fallback root trace id must be non-zero"
done
pass "malformed or all-zero inherited context is treated as absent and roots a clean trace"

# --- minted-root shape and the opaque-inheritance boundary -------------------
# The honest guarantee is NOT "hex cannot carry data" - an inherited traceparent's
# 24 id bytes are opaque caller-controlled data that firstmate passes through. It
# is that a firstmate-MINTED root is exactly the fixed 55-char W3C form with random
# ids and no free-form field where firstmate could originate a prompt, path, or
# secret (that the lib reads no task prose is asserted separately below).
case "$ROOT_TP" in
  *[!0-9a-f-]*) fail "a minted traceparent must contain only hex and hyphens: $ROOT_TP" ;;
esac
[ "${#ROOT_TP}" -eq 55 ] || fail "a minted traceparent is exactly 55 chars, got ${#ROOT_TP}"
pass "a minted root is the fixed 55-char W3C form (hex and hyphens only), so firstmate originates no free-form content in the carrier"

# The trust boundary, stated as a test: an inherited id is preserved verbatim, so
# whoever set TRACEPARENT controls those bytes (opaque caller data, not firstmate-
# originated).
passthrough=$(fm_trace_context_mint '00-deadbeefdeadbeefdeadbeefdeadbeef-1234567812345678-00')
[ "${passthrough:3:32}" = "deadbeefdeadbeefdeadbeefdeadbeef" ] \
  || fail "an inherited trace id must pass through verbatim (caller-controlled): $passthrough"
pass "an inherited traceparent's id bytes pass through verbatim - opaque caller-controlled data, a bounded fixed-width channel, not a firstmate-originated no-content guarantee"

# --- enablement precedence ---------------------------------------------------

WORK=$(fm_test_tmproot fm-trace-context)
CFG_ON="$WORK/cfg-on"; CFG_OFF="$WORK/cfg-off"
mkdir -p "$CFG_ON" "$CFG_OFF"
: > "$CFG_ON/trace-context"

unset FM_TRACE_CONTEXT
fm_trace_context_enabled "$CFG_OFF" && fail "absent config/trace-context must be off by default"
fm_trace_context_enabled "$CFG_ON" || fail "present config/trace-context must enable"
FM_TRACE_CONTEXT=off fm_trace_context_enabled "$CFG_ON" && fail "FM_TRACE_CONTEXT=off must override a present file"
FM_TRACE_CONTEXT=on fm_trace_context_enabled "$CFG_OFF" || fail "FM_TRACE_CONTEXT=on must override an absent file"
FM_TRACE_CONTEXT=1 fm_trace_context_enabled "$CFG_OFF" || fail "FM_TRACE_CONTEXT=1 must enable"
FM_TRACE_CONTEXT=maybe fm_trace_context_enabled "$CFG_ON" && fail "a non-truthy FM_TRACE_CONTEXT must disable"
FM_TRACE_CONTEXT='' fm_trace_context_enabled "$CFG_ON" || fail "empty FM_TRACE_CONTEXT must defer to a present file (enabled)"
FM_TRACE_CONTEXT='' fm_trace_context_enabled "$CFG_OFF" && fail "empty FM_TRACE_CONTEXT must defer to an absent file (disabled)"
pass "enablement is default-off; FM_TRACE_CONTEXT overrides with truthy/other precedence, and unset or empty defers to config/trace-context"

# --- resolve: default-off omits; enabled mints ------------------------------

NOMETA="$WORK/none.meta"
out=$(fm_trace_context_resolve "$CFG_OFF" "$NOMETA"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] || fail "default-off resolve must omit and return 0 (got rc=$rc out='$out')"
pass "resolve omits the carrier and returns success when the capability is off (byte-identical default)"

out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_OFF" "$NOMETA")
fm_trace_context_valid "$out" || fail "enabled resolve must mint a valid traceparent: $out"
pass "resolve mints a valid traceparent when enabled"

# --- secondmate launch snapshot boundary --------------------------------------
# fm-spawn launches every Secondmate with a non-empty FM_TRACE_CONTEXT snapshot.
# That override must keep winning over later file state for the process lifetime.
# When the snapshot is on, ambient TRACEPARENT decides whether workers join the
# primary trace or start a new root.
PRIMARY_TP='00-abcabcabcabcabcabcabcabcabcabcab-1212121212121212-01'
saved_tp=${TRACEPARENT-__unset__}
unset TRACEPARENT
frozen_off=$(FM_TRACE_CONTEXT=off fm_trace_context_resolve "$CFG_ON" "$WORK/sm-frozen-off.meta")
[ -z "$frozen_off" ] || fail "a Secondmate launched off must stay disabled even after the config file appears: $frozen_off"
frozen_on=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_OFF" "$WORK/sm-frozen-on.meta")
fm_trace_context_valid "$frozen_on" || fail "a Secondmate launched on must stay enabled even while the config file is absent: $frozen_on"
[ "${frozen_on:3:32}" != "${PRIMARY_TP:3:32}" ] || fail "an enabled Secondmate without an ambient carrier must start a new root"
relaunched=$(TRACEPARENT="$PRIMARY_TP" FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$WORK/sm-relaunched.meta")
[ "${relaunched:3:32}" = "${PRIMARY_TP:3:32}" ] || fail "a relaunched secondmate (ambient TRACEPARENT set) must continue the primary trace id: $relaunched"
[ "$saved_tp" = "__unset__" ] || export TRACEPARENT="$saved_tp"
pass "Secondmate launch snapshot stays off or on despite later file state; a relaunched enabled Secondmate continues the primary trace"

# --- recovery: a recorded value is reused verbatim, disabled still omits -----

REC_META="$WORK/rec.meta"
printf 'kind=ship\ntraceparent=%s\nmode=no-mistakes\n' "$VALID" > "$REC_META"
out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$REC_META" '00-ffffffffffffffffffffffffffffffff-1111111111111111-01')
[ "$out" = "$VALID" ] || fail "recovery must reuse the recorded traceparent verbatim, ignoring inherited (got '$out')"
pass "resolve reuses a valid recorded traceparent verbatim on relaunch (stable identity across restarts)"

out=$(fm_trace_context_resolve "$CFG_OFF" "$REC_META")
[ -z "$out" ] || fail "a disabled home must omit even when a traceparent is already recorded (got '$out')"
pass "disabling the capability omits the carrier even for a task with a recorded identity"

CORRUPT_META="$WORK/corrupt.meta"
printf 'traceparent=not-a-valid-traceparent\n' > "$CORRUPT_META"
out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$CORRUPT_META")
fm_trace_context_valid "$out" || fail "a corrupt recorded value must be re-minted to a valid one"
[ "$out" != "not-a-valid-traceparent" ] || fail "a corrupt recorded value must not be reused"
pass "a corrupt recorded traceparent is re-minted rather than propagated"

# --- durable metadata consistency: one value for record and injection --------

out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$NOMETA")
fm_trace_context_valid "$out" || fail "resolve must yield a single valid carrier per call"
pass "resolve yields exactly one carrier per logical task, so the recorded and injected values are identical by construction"

# --- entropy failure omits telemetry safely (never aborts) -------------------

fm_trace_context_hex() { return 1; }
ef_mint=$(fm_trace_context_mint ""); ef_mint_rc=$?
ef_res=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$NOMETA"); ef_res_rc=$?
# Restore the real entropy source for any later use.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
[ -z "$ef_mint" ] && [ "$ef_mint_rc" -ne 0 ] || fail "mint must omit and report failure on entropy failure (rc=$ef_mint_rc out='$ef_mint')"
[ -z "$ef_res" ] && [ "$ef_res_rc" -eq 0 ] || fail "resolve must omit and STILL return 0 on entropy failure (rc=$ef_res_rc out='$ef_res')"
pass "entropy failure omits telemetry safely: mint reports failure, resolve returns success with no carrier"

# --- fail-independent timing: no hang source, always returns 0 ---------------

assert_no_grep 'sleep' "$ROOT/bin/fm-trace-context-lib.sh" "trace-context lib must not sleep on the spawn path"
assert_no_grep 'timeout' "$ROOT/bin/fm-trace-context-lib.sh" "trace-context lib must not depend on an external timeout"
assert_no_grep 'command:' "$ROOT/bin/fm-trace-context-lib.sh" "trace-context lib must not run an arbitrary command provider"
fm_trace_context_resolve "$CFG_OFF" "$NOMETA" >/dev/null || fail "resolve must return 0 when off"
pass "the resolver has no sleep/timeout/command hang source and always returns success"

# --- harness/backend/kind independence (code only, comments stripped) ---------

LIB_CODE=$(sed 's/#.*$//' "$ROOT/bin/fm-trace-context-lib.sh")
for tok in harness backend tmux herdr zellij orca cmux claude codex opencode grok kind ship scout secondmate ; do
  case "$LIB_CODE" in
    *"$tok"*) fail "trace-context lib code must be harness/backend/kind agnostic, but references '$tok'" ;;
  esac
done
pass "the carrier is minted identically for every harness, backend, and spawn kind (no such branching in the lib code)"

# --- no prompt / task-prose reads (code only, comments stripped) --------------

for tok in brief prompt report status ; do
  case "$LIB_CODE" in
    *"$tok"*) fail "trace-context lib code must never read task prose, but references '$tok'" ;;
  esac
done
pass "the lib code never reads a brief, prompt, report, or status - it cannot leak content"

# --- structural wiring in bin/fm-spawn.sh ------------------------------------

SPAWN="$ROOT/bin/fm-spawn.sh"
# Patterns deliberately start after any leading '$' so the fixed-string grep needs
# no shell metacharacters while still pinning the exact wiring.
assert_grep 'fm-trace-context-lib.sh' "$SPAWN" "fm-spawn.sh must source the trace-context lib"
assert_grep 'SPAWN_TRACEPARENT=' "$SPAWN" "fm-spawn.sh must assign the resolved carrier"
assert_grep 'fm_trace_context_resolve' "$SPAWN" "fm-spawn.sh must resolve the carrier through the lib entry point"
# shellcheck disable=SC2016 # Dollar signs are literal source text in this fixed-string assertion.
assert_grep '&& spawn_send_text_line "$T" "export TRACEPARENT=$SPAWN_TRACEPARENT"; then' "$SPAWN" \
  "fm-spawn.sh must condition metadata publication on successful carrier delivery"
# shellcheck disable=SC2016 # Dollar signs are literal source text in this fixed-string assertion.
assert_grep 'echo "traceparent=$SPAWN_TRACEPARENT" >> "$STATE/$ID.meta"' "$SPAWN" \
  "fm-spawn.sh must record the delivered carrier in metadata"
assert_grep 'export TRACEPARENT=' "$SPAWN" "fm-spawn.sh must inject the W3C TRACEPARENT env var"
pass "fm-spawn.sh sources the lib and records one shared SPAWN_TRACEPARENT only after successful injection"

# The injection must ride the same channel and site as GOTMPDIR (before launch,
# unconditional across kinds): the TRACEPARENT export follows the GOTMPDIR export.
gotmp_line=$(grep -n 'export GOTMPDIR=' "$SPAWN" | tail -1 | cut -d: -f1)
tp_line=$(grep -n 'export TRACEPARENT=' "$SPAWN" | tail -1 | cut -d: -f1)
# shellcheck disable=SC2016 # Dollar signs are literal source text in this grep pattern.
meta_line=$(grep -n 'echo "traceparent=$SPAWN_TRACEPARENT" >>' "$SPAWN" | tail -1 | cut -d: -f1)
[ -n "$gotmp_line" ] && [ -n "$tp_line" ] && [ -n "$meta_line" ] \
  && [ "$tp_line" -gt "$gotmp_line" ] && [ "$((tp_line - gotmp_line))" -le 5 ] \
  && [ "$meta_line" -gt "$tp_line" ] \
  || fail "TRACEPARENT must be exported before metadata publication at the pre-launch GOTMPDIR site (gotmp=$gotmp_line tp=$tp_line meta=$meta_line)"
pass "TRACEPARENT is injected at the unconditional pre-launch GOTMPDIR site and recorded only after successful delivery"

# --- secondmate inheritance wires the nested chain ---------------------------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
case " $FM_INHERITABLE_CONFIG " in
  *" trace-context "*) : ;;
  *) fail "config/trace-context must be in FM_INHERITABLE_CONFIG so secondmate homes stay traced" ;;
esac
pass "config/trace-context is inherited into secondmate homes, keeping the nested chain enabled end to end"

echo "# fm-trace-context-lib.test.sh: all assertions passed"
