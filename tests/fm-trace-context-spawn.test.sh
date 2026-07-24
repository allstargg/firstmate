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

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

meta_traceparent() { sed -n 's/^traceparent=//p' "$1"; }
injected_traceparent() { sed -n 's/^export TRACEPARENT=//p' "$1"; }

test_enabled_records_and_injects_identical_carrier_before_launch() {
  local rec out status meta mtp itp gl tl ll
  rec=$(make_spawn_case tc-on)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"   # enable via the real config path

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

test_relaunch_reuses_recorded_carrier() {
  local rec out status meta first second injected
  rec=$(make_spawn_case tc-relaunch)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
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

test_env_override_wins_over_file() {
  local rec out status meta
  # FM_TRACE_CONTEXT=off must disable even a file-enabled home.
  rec=$(make_spawn_case tc-envoff)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  out=$(run_spawn_tc off "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "env-off spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "env-off spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  ! grep -q '^traceparent=' "$meta" || fail "FM_TRACE_CONTEXT=off must disable even a file-enabled home"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" || fail "FM_TRACE_CONTEXT=off must inject nothing even with the file present"

  # FM_TRACE_CONTEXT=on must enable a home with no config file.
  rec=$(make_spawn_case tc-envon)
  read_case_record "$rec"
  out=$(run_spawn_tc on "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "env-on spawn should succeed"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  fm_trace_context_valid "$(meta_traceparent "$meta")" \
    || fail "FM_TRACE_CONTEXT=on must enable even with no config file"
  pass "FM_TRACE_CONTEXT overrides the file both ways: off disables a file-enabled home, on enables a fileless home"
}

test_enabled_records_and_injects_identical_carrier_before_launch
test_disabled_writes_and_injects_neither
test_relaunch_reuses_recorded_carrier
test_env_override_wins_over_file

echo "# all fm-trace-context-spawn tests passed"
