# shellcheck shell=bash
# Native W3C trace-context propagation for firstmate spawns (default-off).
#
# When enabled, firstmate resolves one W3C `traceparent` carrier for a task,
# injects it into the agent's pane shell as the TRACEPARENT environment variable
# before launch (bin/fm-spawn.sh, alongside GOTMPDIR, so it reaches every spawn
# backend and every harness for ship, scout, and secondmate spawns), and records
# the identical value as `traceparent=` in state/<id>.meta. Because the injected
# carrier and the recorded carrier are the same string, an observer that reads
# the metadata sees exactly the identity the child received - no collector,
# storage, UI, or vendor coupling.
#
# TRACEPARENT here is a firstmate CONVENTION that carries a W3C-formatted
# traceparent value in the process environment. W3C Trace Context standardizes
# the `traceparent` HTTP header, not an environment variable, and OpenTelemetry
# SDKs do NOT read TRACEPARENT from the environment automatically. A downstream
# observer or instrumentation must explicitly read this env value (or the meta
# field); this library parents no SDK span by itself.
#
# Identity is per TASK, not per spawn: the carrier is minted on the first spawn,
# adopted as a child (fresh span, same trace) for a nested spawn whose parent
# already holds one, and REUSED verbatim from the meta on relaunch/recovery, so a
# task keeps one stable logical identity across restarts.
#
# Usage: . bin/fm-trace-context-lib.sh   (pure function library, no side effects)
#
# Public entry point used by bin/fm-spawn.sh:
#   fm_trace_context_resolve <config-dir> <meta-file> [<inherited-traceparent>]
#     Echoes the traceparent to inject AND record, or nothing when the
#     capability is off or when entropy or self-validation fails. A malformed or
#     all-zero inherited value is NOT an omission: it is treated as absent and a
#     fresh root is minted (see the root/child rules below). It ALWAYS returns 0:
#     telemetry is omitted safely and never aborts the spawn. The third argument
#     defaults to $TRACEPARENT so a nested secondmate or worker spawn continues
#     its parent's trace; pass an explicit value (including empty) to override,
#     mainly for tests.
#
# Enablement (see docs/configuration.md for the schema):
#   config/trace-context   presence flag under the home's config dir enables it.
#   FM_TRACE_CONTEXT        env override: 1/on/true/yes enables, any other
#                           non-empty value disables, and unset OR empty defers
#                           to the file.
#   At launch, the primary propagates config/trace-context into the secondmate
#   home (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh) AND snapshots
#   its own effective on/off decision into the new process as a non-empty
#   FM_TRACE_CONTEXT value in the launch prefix (bin/fm-spawn.sh).
#   Because that environment override wins over the copied file, the snapshot is
#   fixed for the secondmate process lifetime: on keeps its workers enabled and
#   off keeps them disabled. Live config convergence leaves trace-context
#   unchanged so a legacy process without a launch snapshot cannot switch state.
#   Relaunching the secondmate snapshots the primary's then-current decision and,
#   when enabled, carries the primary's trace into nested workers.
#
# Wire shape: version 00 only, "00-<32 hex trace>-<16 hex span>-<2 hex flags>",
# with the trace id and span id never all-zero (W3C rejects both). New roots use
# RANDOM ids from /dev/urandom. A `01` (sampled) flag on a root records a
# sampling DECISION that downstream parent-based samplers honor; it does not
# guarantee any collector stores a span, and firstmate emits no spans itself. A
# child preserves the inherited flag verbatim.
#
# Security / trust boundary. This feature adds no OTEL_* variables, no
# tracestate, no arbitrary environment injection, and no configurable or
# arbitrary command execution. It DOES run the fixed local utilities `od` and
# `tr` (resolved from PATH) to read a few bytes of entropy - a small local
# pipeline with no configured provider, network, or watchdog, and no hard latency
# guarantee; any failure that returns omits the carrier without aborting the spawn. A firstmate-MINTED root is random and reads no prompt, path,
# task prose, credential, or arbitrary environment key. An INHERITED traceparent,
# by contrast, is opaque caller-controlled data: its 16-byte trace id and 8-byte
# span id are up to 24 bytes (48 hex chars) that firstmate accepts after syntax
# validation WITHOUT interpreting, so whoever set TRACEPARENT in firstmate's
# environment (a trusted local operator or observer) controls those bytes.
# Exposure is bounded to that fixed-width carrier - it is not a general content
# or secret channel, but it is not "structurally impossible to carry data" either.
#
# Root / child / recovery semantics (never mint an unrelated root by accident):
#   recovery - a valid traceparent already recorded in the meta file is reused
#              verbatim, so a relaunched or recovered task keeps one stable
#              identity across restarts.
#   child    - a valid inherited traceparent contributes its trace id and flags
#              while a fresh span id is minted, so nested spawns share one trace.
#   root     - with no valid inherited context a fresh random trace id, fresh
#              span id, and sampled flags (01) begin a new trace. A malformed or
#              all-zero inherited value is treated as absent, so garbage never
#              propagates.

# Strict W3C traceparent validator: version 00, 32-hex trace id, 16-hex span id,
# 2-hex flags, with neither id all-zero. The regex lives in a variable because
# bash 3.2 only honors an unquoted right-hand side for =~.
fm_trace_context_valid() {  # <traceparent>
  local tp=$1
  local re='^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'
  [[ $tp =~ $re ]] || return 1
  [ "${tp:3:32}" = "00000000000000000000000000000000" ] && return 1
  [ "${tp:36:16}" = "0000000000000000" ] && return 1
  return 0
}

# Echo <byte-count> random bytes as lowercase hex, or echo nothing and return 1
# on any entropy failure (unreadable source, short read, non-hex). -v stops od
# from collapsing repeated byte lines to '*'; the explicit length and charset
# checks turn a masked pipeline failure into a clean omission upstream.
fm_trace_context_hex() {  # <byte-count>
  local bytes=$1 hex
  hex=$(LC_ALL=C od -An -v -tx1 -N "$bytes" /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  case "$hex" in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#hex}" -eq "$((bytes * 2))" ] || return 1
  printf '%s' "$hex"
}

# True when the capability is enabled for this home. The env override wins so a
# spawn can be forced on or off without touching the file; otherwise the
# presence of config/trace-context decides, and its absence is the default-off.
fm_trace_context_enabled() {  # <config-dir>
  local config_dir=$1 v
  # A non-empty value is an explicit override; unset OR empty defers to the file
  # (the conventional "empty is like unset" behavior).
  if [ -n "${FM_TRACE_CONTEXT:-}" ]; then
    v=$(printf '%s' "$FM_TRACE_CONTEXT" | tr '[:upper:]' '[:lower:]')
    case "$v" in
      1 | on | true | yes) return 0 ;;
      *) return 1 ;;
    esac
  fi
  [ -f "$config_dir/trace-context" ]
}

# Echo any traceparent already recorded in <meta-file>, else nothing. Used for
# the recovery path so a relaunch reuses the first spawn's identity.
fm_trace_context_recorded() {  # <meta-file>
  local meta=$1 line
  [ -f "$meta" ] || return 0
  line=$(grep '^traceparent=' "$meta" 2>/dev/null | head -n1) || return 0
  printf '%s' "${line#traceparent=}"
}

# Mint a traceparent, adopting a valid parent's trace id and flags when present,
# otherwise starting a fresh root. Echo nothing and return 1 on entropy or
# validation failure so the caller can omit telemetry.
fm_trace_context_mint() {  # <inherited-traceparent-or-empty>
  local inherited=$1 trace flags span tp
  if fm_trace_context_valid "$inherited"; then
    trace=${inherited:3:32}
    flags=${inherited:53:2}
  else
    trace=$(fm_trace_context_hex 16) || return 1
    flags=01
  fi
  span=$(fm_trace_context_hex 8) || return 1
  tp="00-$trace-$span-$flags"
  fm_trace_context_valid "$tp" || return 1
  printf '%s' "$tp"
}

# Public entry point. Echo the single carrier to inject and record, or nothing.
# Always returns 0 so a spawn is never aborted by a telemetry decision.
fm_trace_context_resolve() {  # <config-dir> <meta-file> [<inherited-traceparent>]
  local config_dir=$1 meta=$2 inherited=${3-${TRACEPARENT:-}} existing
  fm_trace_context_enabled "$config_dir" || return 0
  existing=$(fm_trace_context_recorded "$meta")
  if fm_trace_context_valid "$existing"; then
    printf '%s' "$existing"
    return 0
  fi
  fm_trace_context_mint "$inherited" || return 0
}
