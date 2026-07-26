#!/usr/bin/env bash
# tests/fm-trace-context-spawn.test.sh - spawn-path integration regression for
# native W3C trace context. Drives bin/fm-spawn.sh through real meta writing and
# the real pre-launch injection with a fake tmux pane and a real isolated git
# worktree, so it proves the actual spawn behavior (not just that the source
# text mentions the right symbols): enabled, the one resolved carrier is written
# to state/<id>.meta AND the identical TRACEPARENT export is sent before the
# launch literal; disabled, neither is written nor sent; and a relaunch reuses
# the recorded carrier. The fake tmux captures every `send-keys -l` line, so no
# real harness or live fleet is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-trace-context-spawn)

# Fake tmux: answers the pane-path query and logs every literal `send-keys -l`
# argument (the GOTMPDIR export, the TRACEPARENT export, and the launch command)
# one per line, in send order, so ordering is observable.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ "${FM_FAKE_TRACEPARENT_SEND_FAIL:-0}" = 1 ]; then
      for a in "$@"; do
        case "$a" in
          "export TRACEPARENT="*) exit 1 ;;
        esac
      done
    fi
    # Capture the text payload of both send forms: the literal launch
    # (`send-keys -t <target> -l <text>`) and a text line
    # (`send-keys -t <target> <text> Enter`). Skip the flags, the target, and
    # the trailing key so only the payload is logged, one per line, in order.
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'off\n' > "$home/state/.trace-context-effective"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

# Hermetic against an ambient FM_TRACE_CONTEXT: `env -u` unsets it so enablement
# is decided ONLY by the home's config/trace-context, whether the runner's own
# environment enables or disables trace context.
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TRACEPARENT_SEND_FAIL="${FM_FAKE_TRACEPARENT_SEND_FAIL:-0}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Same, but with an explicit FM_TRACE_CONTEXT override, to prove the env decides.
run_spawn_tc() {
  local tc=$1 home=$2 wt=$3 fakebin=$4 launchlog=$5
  shift 5
  : > "$launchlog"
  env FM_TRACE_CONTEXT="$tc" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

start_trace_session() {
  local home=$1 tc=${2-}
  if [ -n "$tc" ]; then
    FM_TRACE_CONTEXT="$tc" fm_trace_context_session_start \
      "$home/config" "$home/state/.trace-context-effective"
  else
    (
      unset FM_TRACE_CONTEXT
      fm_trace_context_session_start \
        "$home/config" "$home/state/.trace-context-effective"
    )
  fi
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

meta_traceparent() { sed -n 's/^traceparent=//p' "$1"; }
injected_traceparent() { sed -n 's/^export TRACEPARENT=//p' "$1"; }

# Two-level primary -> secondmate -> worker regression for the FM_TRACE_CONTEXT
# effective override. Drives bin/fm-spawn.sh TWICE against real homes and a real
# worktree: first the primary launches a secondmate (capturing the exact env the
# primary injects into it), then that secondmate launches its OWN worker with
# exactly that inherited env, reading the secondmate home's own inherited config.
# This is what proves the primary's effective on/off decision - not only the
# copied config/trace-context file - governs the nested worker, which a
# single-home spawn test cannot reach. Sets TL_ENV_TC, TL_CARRIER, TL_WORKER_TP,
# and TL_SM_FILE for the caller.
#   run_two_level <name> <present|absent primary file> <on|off primary env>
run_two_level() {
  local name=$1 pfile=$2 penv=$3
  local base prim sm sm_id smlog smfake worker_id wproj wwt wlog wfake
  base="$TMP_ROOT/2level-$name"
  prim="$base/primary"
  sm="$base/sm"
  mkdir -p "$prim/config" "$prim/data" "$prim/state" "$prim/projects"
  printf 'claude\n' > "$prim/config/crew-harness"
  [ "$pfile" = present ] && : > "$prim/config/trace-context"
  touch "$prim/state/.last-watcher-beat"
  start_trace_session "$prim" "$penv"

  # Seed the secondmate home so validate_firstmate_home_for_spawn accepts it.
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf 'sm-%s\n' "$name" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"

  # Spawn 1: the primary launches the secondmate; capture what it injects.
  sm_id="sm-$name"
  mkdir -p "$prim/data/$sm_id"
  printf 'charter brief\n' > "$prim/data/$sm_id/brief.md"
  smlog="$base/sm-launch.log"
  smfake=$(make_spawn_fakebin "$base/sm-fake")
  : > "$smlog"
  env FM_TRACE_CONTEXT="$penv" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$prim" \
    FM_STATE_OVERRIDE="$prim/state" FM_DATA_OVERRIDE="$prim/data" \
    FM_PROJECTS_OVERRIDE="$prim/projects" FM_CONFIG_OVERRIDE="$prim/config" \
    FM_SPAWN_NO_GUARD=1 CLAUDECODE=1 TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$smlog" PATH="$smfake:$PATH" \
    "$SPAWN" "$sm_id" "$sm" --secondmate >/dev/null 2>&1 || true

  # Extract the EXACT env the primary put on the secondmate: the normalized
  # FM_TRACE_CONTEXT in the launch prefix, and the TRACEPARENT carrier (if any).
  TL_ENV_TC=$(grep -o 'FM_TRACE_CONTEXT=[a-z]*' "$smlog" | head -1 | cut -d= -f2)
  TL_CARRIER=$(injected_traceparent "$smlog" | head -1)

  # Spawn 2: the secondmate launches its own worker with exactly that inherited
  # env, reading the secondmate home's own (inherited) config.
  worker_id="w-$name"
  wproj="$base/wproj"
  wwt="$base/wwt"
  fm_git_worktree "$wproj" "$wwt" "wt-$name"
  mkdir -p "$sm/state" "$sm/projects" "$sm/data/$worker_id"
  printf 'worker brief\n' > "$sm/data/$worker_id/brief.md"
  touch "$sm/state/.last-watcher-beat"
  start_trace_session "$sm" "$TL_ENV_TC"
  wlog="$base/worker-launch.log"
  wfake=$(make_spawn_fakebin "$base/w-fake")
  : > "$wlog"
  env FM_TRACE_CONTEXT="$TL_ENV_TC" TRACEPARENT="$TL_CARRIER" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$sm" \
    FM_STATE_OVERRIDE="$sm/state" FM_DATA_OVERRIDE="$sm/data" \
    FM_PROJECTS_OVERRIDE="$sm/projects" FM_CONFIG_OVERRIDE="$sm/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wwt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$wlog" PATH="$wfake:$PATH" \
    "$SPAWN" "$worker_id" "$wproj" >/dev/null 2>&1 || true

  TL_WORKER_TP=$(meta_traceparent "$sm/state/$worker_id.meta")
  TL_SM_FILE=absent
  [ -f "$sm/config/trace-context" ] && TL_SM_FILE=present
}

test_enabled_records_and_injects_identical_carrier_before_launch() {
  local rec out status meta mtp itp gl tl ll
  rec=$(make_spawn_case tc-on)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"   # enable via the real config path
  start_trace_session "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "enabled trace-context spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "enabled spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  mtp=$(meta_traceparent "$meta")
  fm_trace_context_valid "$mtp" || fail "enabled spawn must record a valid traceparent= in meta (got '$mtp')"
  itp=$(injected_traceparent "$LAUNCH_LOG")
  fm_trace_context_valid "$itp" || fail "enabled spawn must inject a valid TRACEPARENT export (got '$itp')"
  [ "$mtp" = "$itp" ] || fail "the recorded and injected carriers must be identical (meta='$mtp' injected='$itp')"

  gl=$(grep -n '^export GOTMPDIR=' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  tl=$(grep -n '^export TRACEPARENT=' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  ll=$(grep -n 'claude' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  [ -n "$gl" ] && [ -n "$tl" ] && [ -n "$ll" ] || fail "launch log missing GOTMPDIR/TRACEPARENT/launch lines"
  [ "$tl" -gt "$gl" ] || fail "TRACEPARENT export must ride the GOTMPDIR pre-launch site (gotmp=$gl tp=$tl)"
  [ "$tl" -lt "$ll" ] || fail "TRACEPARENT export must be sent before the launch literal (tp=$tl launch=$ll)"
  pass "enabled: one resolved carrier is recorded in meta and the identical TRACEPARENT is exported before launch"
}

test_disabled_writes_and_injects_neither() {
  local rec out status meta
  rec=$(make_spawn_case tc-off)
  read_case_record "$rec"
  # No config/trace-context and no FM_TRACE_CONTEXT: default-off.

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "default-off spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "default-off spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  # Anchored regex checks (the assert_grep helpers are fixed-string).
  ! grep -q '^traceparent=' "$meta" || fail "default-off spawn must not write a traceparent= line to meta"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" || fail "default-off spawn must not inject a TRACEPARENT export"
  grep -q '^export GOTMPDIR=' "$LAUNCH_LOG" || fail "the spawn should still run (GOTMPDIR is always injected)"
  pass "disabled: neither traceparent= in meta nor a TRACEPARENT export is produced"
}

test_failed_delivery_omits_metadata_and_still_launches() {
  local rec out status meta
  rec=$(make_spawn_case tc-send-failure)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"

  out=$(FM_FAKE_TRACEPARENT_SEND_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "failed traceparent delivery must not abort spawn"
  assert_contains "$out" "spawned $CASE_ID" "spawn should report success after failed traceparent delivery"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  ! grep -q '^traceparent=' "$meta" \
    || fail "failed traceparent delivery must not leave a traceparent= claim in meta"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" \
    || fail "the failed TRACEPARENT export must not be recorded as delivered"
  grep -q 'claude' "$LAUNCH_LOG" || fail "the source task must still launch"
  pass "failed TRACEPARENT delivery omits metadata while the source task still launches"
}

test_relaunch_reuses_recorded_carrier() {
  local rec out status meta first second injected
  rec=$(make_spawn_case tc-relaunch)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "first trace-context spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "first spawn should report success"
  first=$(meta_traceparent "$meta")
  fm_trace_context_valid "$first" || fail "first spawn must record a valid carrier (got '$first')"

  # Relaunch the same task: the recorded carrier must be reused verbatim for both
  # the meta and the injected export, so an observer keeps one identity across
  # restarts.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "relaunch spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "relaunch spawn should report success"
  second=$(meta_traceparent "$meta")
  injected=$(injected_traceparent "$LAUNCH_LOG")
  [ "$second" = "$first" ] || fail "relaunch must reuse the recorded carrier in meta (first='$first' second='$second')"
  [ "$injected" = "$first" ] || fail "relaunch must inject the same recorded carrier (first='$first' injected='$injected')"
  pass "relaunch reuses the recorded carrier verbatim for both the meta record and the injected export"
}

test_session_start_freezes_env_override_and_ignores_later_edits() {
  local rec out status meta
  rec=$(make_spawn_case tc-envoff)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR" off
  out=$(run_spawn_tc on "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "env-off spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "env-off spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  ! grep -q '^traceparent=' "$meta" || fail "session-frozen off must ignore a later FM_TRACE_CONTEXT=on"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" || fail "session-frozen off must remain disabled after launch-time edits"

  rec=$(make_spawn_case tc-envon)
  read_case_record "$rec"
  start_trace_session "$HOME_DIR" on
  : > "$HOME_DIR/config/trace-context"
  out=$(run_spawn_tc off "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "env-on spawn should succeed"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  fm_trace_context_valid "$(meta_traceparent "$meta")" \
    || fail "session-frozen on must ignore a later FM_TRACE_CONTEXT=off"
  pass "session start freezes the env override and later config or environment edits do not alter spawns"
}

# End-to-end two-level enable path: the primary is enabled by the environment
# override with NO config file, and that enablement must reach the newly launched
# secondmate's own worker so the whole chain shares one trace. Before the
# effective-override fix, the secondmate saw only the (absent) inherited file and
# left its worker untraced despite receiving the parent carrier.
test_secondmate_env_on_file_absent_keeps_nested_worker_enabled() {
  run_two_level enable absent on
  [ "$TL_ENV_TC" = on ] || fail "the primary must deliver FM_TRACE_CONTEXT=on to the secondmate (got '$TL_ENV_TC')"
  fm_trace_context_valid "$TL_CARRIER" || fail "an enabled primary must mint a carrier for the secondmate (got '$TL_CARRIER')"
  fm_trace_context_valid "$TL_WORKER_TP" \
    || fail "env-on/file-absent must keep the nested worker enabled (got '$TL_WORKER_TP')"
  [ "${TL_CARRIER:3:32}" = "${TL_WORKER_TP:3:32}" ] \
    || fail "the nested worker must share the primary trace id (parent='${TL_CARRIER:3:32}' worker='${TL_WORKER_TP:3:32}')"
  [ "${TL_CARRIER:36:16}" != "${TL_WORKER_TP:36:16}" ] \
    || fail "the nested worker must mint a fresh span id, not reuse the parent's"
  pass "two-level: env-on/file-absent keeps the nested worker enabled and in the same trace as the primary"
}

# End-to-end two-level disable path: the primary is disabled by the environment
# override while the config file is PRESENT (so it is copied into the secondmate
# home). The override must still disable the secondmate's own worker, or
# FM_TRACE_CONTEXT=off is not a real kill switch. Before the fix the copied file
# re-enabled the nested worker.
test_secondmate_env_off_file_present_keeps_nested_worker_disabled() {
  run_two_level disable present off
  [ "$TL_ENV_TC" = off ] || fail "the primary must deliver FM_TRACE_CONTEXT=off to the secondmate (got '$TL_ENV_TC')"
  [ -z "$TL_CARRIER" ] || fail "a disabled primary must inject no carrier into the secondmate (got '$TL_CARRIER')"
  [ "$TL_SM_FILE" = present ] \
    || fail "the disable case must exercise a copied config/trace-context in the secondmate home (got '$TL_SM_FILE')"
  [ -z "$TL_WORKER_TP" ] \
    || fail "env-off must keep the nested worker disabled even with the file present (got '$TL_WORKER_TP')"
  pass "two-level: env-off/file-present keeps the nested worker disabled even though the config file was copied into the secondmate home"
}

# Single-frozen-decision guarantee: for a secondmate spawn the recorded/injected
# carrier and the delivered FM_TRACE_CONTEXT snapshot are always derived from ONE
# effective decision, so they cannot disagree (no carrier paired with off, no
# off snapshot paired with a carrier). This drives the file-decided path
# (FM_TRACE_CONTEXT unset), which is exactly where the two-read correction matters
# because the environment override is empty and only the config file decides.
test_secondmate_carrier_and_snapshot_share_one_decision() {
  run_two_level fileon present ""
  [ "$TL_ENV_TC" = on ] || fail "a file-enabled secondmate must snapshot FM_TRACE_CONTEXT=on (got '$TL_ENV_TC')"
  fm_trace_context_valid "$TL_CARRIER" \
    || fail "a file-enabled secondmate's carrier must be present and valid, consistent with the on snapshot (got '$TL_CARRIER')"

  run_two_level fileoff absent ""
  [ "$TL_ENV_TC" = off ] || fail "a file-disabled secondmate must snapshot FM_TRACE_CONTEXT=off (got '$TL_ENV_TC')"
  [ -z "$TL_CARRIER" ] \
    || fail "a file-disabled secondmate must inject no carrier, consistent with the off snapshot (got '$TL_CARRIER')"
  pass "secondmate carrier and FM_TRACE_CONTEXT snapshot always agree, both derived from one frozen decision (file-decided path)"
}

test_enabled_records_and_injects_identical_carrier_before_launch
test_disabled_writes_and_injects_neither
test_failed_delivery_omits_metadata_and_still_launches
test_relaunch_reuses_recorded_carrier
test_session_start_freezes_env_override_and_ignores_later_edits
test_secondmate_env_on_file_absent_keeps_nested_worker_enabled
test_secondmate_env_off_file_present_keeps_nested_worker_disabled
test_secondmate_carrier_and_snapshot_share_one_decision

echo "# all fm-trace-context-spawn tests passed"
