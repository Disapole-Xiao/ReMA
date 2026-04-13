#!/usr/bin/env bash
# ReMA test suite
# Usage: bash test_rema.sh
set -uo pipefail

TEST_NAME="test-$$"
PASS=0
FAIL=0
TOTAL=0
REMA_CMD="${1:-rema}"

#--- Helpers ---

expect_eq() {
  local desc="$1" got="$2" want="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$want" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        got:  '$got'"
    echo "        want: '$want'"
    FAIL=$((FAIL + 1))
  fi
}

expect_contains() {
  local desc="$1" got="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$got" | grep -q "$pattern"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        got:      '$got'"
    echo "        expected: contains '$pattern'"
    FAIL=$((FAIL + 1))
  fi
}

expect_fail() {
  local desc="$1" output="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qi "$pattern"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        got:      '$output'"
    echo "        expected: error containing '$pattern'"
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  $REMA_CMD stop "$TEST_NAME" 2>/dev/null || true
  $REMA_CMD rm "$TEST_NAME" 2>/dev/null || true
  rm -rf /tmp/rema/"$TEST_NAME" 2>/dev/null || true
}

#--- Tests ---

echo "=== ReMA Test Suite ==="
echo "  test machine: $TEST_NAME"
echo ""

# 1. Start
echo "[1] start"
cleanup
out=$($REMA_CMD start "$TEST_NAME" 2>&1)
expect_contains "start prints worker started" "$out" "worker '$TEST_NAME' started"
expect_contains "start prints work directory" "$out" "work directory:"
expect_contains "start prints log path" "$out" "worker.log"

# 2. Status after start
echo "[2] status after start"
out=$($REMA_CMD status "$TEST_NAME" 2>&1)
expect_eq "status is idle" "$out" "idle"

# 3. Shared dir structure
echo "[3] file layout"
sdir=$($REMA_CMD list 2>&1 | head -1) # just to confirm REMA_DIR is set
sdir=$(grep -o 'REMA_DIR=.*' ~/.rema_config 2>/dev/null | head -1 | cut -d= -f2-)
if [ -z "$sdir" ]; then sdir="${REMA_DIR:-}"; fi
expect_eq "shared dir exists" "$([ -d "$sdir/$TEST_NAME" ] && echo yes || echo no)" "yes"
expect_eq "status file in shared dir" "$([ -f "$sdir/$TEST_NAME/status" ] && echo yes || echo no)" "yes"
expect_eq "heartbeat in shared dir" "$([ -f "$sdir/$TEST_NAME/heartbeat" ] && echo yes || echo no)" "yes"
expect_eq "workdir in shared dir" "$([ -f "$sdir/$TEST_NAME/workdir" ] && echo yes || echo no)" "yes"
expect_eq "pid NOT in shared dir" "$([ -f "$sdir/$TEST_NAME/pid" ] && echo yes || echo no)" "no"
expect_eq "worker.log NOT in shared dir" "$([ -f "$sdir/$TEST_NAME/output/worker.log" ] && echo yes || echo no)" "no"
expect_eq "pid in local dir" "$([ -f "/tmp/rema/$TEST_NAME/pid" ] && echo yes || echo no)" "yes"
expect_eq "worker.log in local dir" "$([ -f "/tmp/rema/$TEST_NAME/worker.log" ] && echo yes || echo no)" "yes"

# 4. List
echo "[4] list"
out=$($REMA_CMD list 2>&1)
expect_contains "list shows machine" "$out" "$TEST_NAME"
expect_contains "list shows idle" "$out" "idle"

# 5. Sync run
echo "[5] sync run"
out=$($REMA_CMD run "$TEST_NAME" -- echo "hello rema" 2>&1)
expect_contains "sync run outputs command result" "$out" "hello rema"
expect_contains "sync run shows exit code 0" "$out" "exit code: 0"

# 6. Work directory
echo "[6] work directory"
out=$($REMA_CMD run "$TEST_NAME" -- pwd 2>&1)
# workdir should be the directory where start was run
expected_workdir=$(cat "$sdir/$TEST_NAME/workdir" 2>/dev/null)
got_workdir=$(echo "$out" | grep "^/" | head -1 | tr -d ' ')
expect_eq "workdir matches start directory" "$got_workdir" "$expected_workdir"

# 7. Async run + log
echo "[7] async run + log"
out=$($REMA_CMD run "$TEST_NAME" --async -- echo "async test" 2>&1)
expect_contains "async returns job_id" "$out" "job submitted"
job_id=$(echo "$out" | grep -o 'job_id: [^)]*' | cut -d' ' -f2)
# Wait for log file to appear (worker polls every 10s)
logfile="$sdir/$TEST_NAME/output/${job_id}.log"
waited=0
while [ ! -f "$logfile" ] && [ "$waited" -lt 30 ]; do
  sleep 1
  waited=$((waited + 1))
done
out=$($REMA_CMD log "$TEST_NAME" "$job_id" 2>&1)
expect_contains "log shows async output" "$out" "async test"

# 8. Heartbeat stays fresh during busy (must exceed heartbeat interval)
echo "[8] heartbeat during busy"
# Wait for previous async job to finish and worker to go idle
sleeped=0
while [ "$($REMA_CMD status "$TEST_NAME" 2>&1)" != "idle" ] && [ "$sleeped" -lt 15 ]; do
  sleep 1; sleeped=$((sleeped + 1))
done
# Submit a command that runs longer than heartbeat interval (10s)
$REMA_CMD run "$TEST_NAME" --async -- "sleep 20" >/dev/null 2>&1
sleep 12  # wait > heartbeat interval, heartbeat must have updated at least once
status=$($REMA_CMD status "$TEST_NAME" 2>&1)
expect_eq "status is busy after 12s" "$status" "busy"
# Check heartbeat is fresh (< 15s, meaning it was updated during busy)
heartbeat_file="$sdir/$TEST_NAME/heartbeat"
heartbeat_ts=$(cat "$heartbeat_file" 2>/dev/null)
now_ts=$(date +%s)
age=$((now_ts - heartbeat_ts))
TOTAL=$((TOTAL + 1))
if [ "$age" -lt 15 ]; then
  echo "  PASS: heartbeat is fresh during busy ($age s)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat is stale during busy ($age s)"
  FAIL=$((FAIL + 1))
fi
# Wait for command to finish, then cleanup
sleep 10
$REMA_CMD stop "$TEST_NAME" >/dev/null 2>&1

# 9. Kill running job
echo "[9] kill running job"
$REMA_CMD start "$TEST_NAME" >/dev/null 2>&1
sleep 1
# Submit a long-running command
$REMA_CMD run "$TEST_NAME" --async -- "sleep 60" >/dev/null 2>&1
sleep 2
status=$($REMA_CMD status "$TEST_NAME" 2>&1)
expect_eq "status is busy before kill" "$status" "busy"
# Kill it
out=$($REMA_CMD kill "$TEST_NAME" 2>&1)
expect_contains "kill reports success" "$out" "killed"
# Status should be idle now
status=$($REMA_CMD status "$TEST_NAME" 2>&1)
expect_eq "status is idle after kill" "$status" "idle"
$REMA_CMD stop "$TEST_NAME" >/dev/null 2>&1

# 10. Run on busy rejects
echo "[10] run on busy rejects"
$REMA_CMD start "$TEST_NAME" >/dev/null 2>&1
sleep 1
$REMA_CMD run "$TEST_NAME" --async -- "sleep 20" >/dev/null 2>&1
# Wait for worker to pick up the job and go busy
waited=0
while [ "$($REMA_CMD status "$TEST_NAME" 2>&1)" != "busy" ] && [ "$waited" -lt 15 ]; do
  sleep 1; waited=$((waited + 1))
done
out=$($REMA_CMD run "$TEST_NAME" -- echo "should not run" 2>&1) || true
expect_fail "run on busy worker rejects" "$out" "busy"
# Wait for job to finish, then stop
sleep 22
$REMA_CMD stop "$TEST_NAME" >/dev/null 2>&1

# 11. Status nonexistent
echo "[11] status nonexistent"
out=$($REMA_CMD status "nonexistent-machine-xyz" 2>&1) || true
expect_fail "status nonexistent errors" "$out" "not found"

# 12. Run nonexistent
echo "[12] run nonexistent"
out=$($REMA_CMD run "nonexistent-machine-xyz" -- echo x 2>&1) || true
expect_fail "run nonexistent errors" "$out" "not found"

# 13. Stop
echo "[13] stop"
$REMA_CMD start "$TEST_NAME" >/dev/null 2>&1
sleep 1
out=$($REMA_CMD stop "$TEST_NAME" 2>&1)
expect_contains "stop reports stopped" "$out" "stopped"
out=$($REMA_CMD status "$TEST_NAME" 2>&1)
expect_eq "status is off after stop" "$out" "off"

# 14. Rm on idle (restart first)
echo "[14] rm on idle"
$REMA_CMD start "$TEST_NAME" >/dev/null 2>&1
sleep 1
out=$($REMA_CMD rm "$TEST_NAME" 2>&1) || true
expect_fail "rm on idle rejects" "$out" "stop"

# 15. Rm on off
echo "[15] rm on off"
$REMA_CMD stop "$TEST_NAME" >/dev/null 2>&1
out=$($REMA_CMD rm "$TEST_NAME" 2>&1)
expect_contains "rm on off succeeds" "$out" "removed"
out=$($REMA_CMD status "$TEST_NAME" 2>&1) || true
expect_fail "status fails after rm" "$out" "not found"

# 16. List empty
echo "[16] list empty"
out=$($REMA_CMD list 2>&1)
# Should not show the removed machine (or show "no machines found" if nothing else registered)
expect_eq "list does not show removed machine" "$(echo "$out" | grep -c "$TEST_NAME" || true)" "0"

#--- Summary ---

cleanup
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
