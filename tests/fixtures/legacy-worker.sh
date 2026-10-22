#!/usr/bin/env bash
# Protocol-1 worker fixture from ReMA e6596b2 (0.1.0).
# Only the original helpers/worker loop are retained; no user config is loaded.
set -uo pipefail
: "${REMA_DIR:?isolated shared directory required}"
: "${REMA_LOCAL_DIR:?isolated local directory required}"
REMA_LOG_KEEP_DAYS=7
REMA_HEARTBEAT_INTERVAL=0.05
REMA_STATUS_TIMEOUT=60
REMA_WORKDIR="$PWD"
die() { echo "rema: $*" >&2; exit 1; }

# Generate unique job_id: timestamp_pid_random
gen_job_id() {
  printf "%s_%s_%s" "$(date +%s%3N)" "$$" "$RANDOM"
}

# Check REMA_DIR is set
check_dir() {
  [ -z "$REMA_DIR" ] && die "REMA_DIR not set. Run install.sh or export REMA_DIR manually."
  mkdir -p "$REMA_DIR"
}

# Get shared machine directory path (cross-machine communication)
machine_dir() { echo "$REMA_DIR/$1"; }

# Get local machine directory path (per-machine state)
local_dir() { echo "$REMA_LOCAL_DIR/$1"; }

# Read a KEY=VALUE field from cmd file
read_cmd_field() {
  local file="$1" key="$2"
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-
}

# Read heartbeat age in seconds
heartbeat_age() {
  local heartbeat_file="$1"
  local ts
  ts=$(cat "$heartbeat_file" 2>/dev/null) || { echo 999; return; }
  echo $(( $(date +%s) - ts ))
}

# Get machine status: off / idle / busy
get_status() {
  local sdir="$1"

  # Check heartbeat freshness
  if [ -f "$sdir/heartbeat" ]; then
    local age
    age=$(heartbeat_age "$sdir/heartbeat")
    if [ "$age" -gt "$REMA_STATUS_TIMEOUT" ]; then
      echo "off"; return
    fi
  else
    echo "off"; return
  fi

  # Read status file
  local status
  status=$(cat "$sdir/status" 2>/dev/null) || status="off"
  echo "$status"
}

# Update heartbeat file
update_heartbeat() {
  local sdir="$1"
  echo "$(date +%s)" > "$sdir/heartbeat"
}

# Clean old logs
clean_old_logs() {
  local sdir="$1"
  find "$sdir/output/" -name "*.log" -mtime +${REMA_LOG_KEEP_DAYS} -delete 2>/dev/null || true
}

#--- Worker loop (internal) ---

_worker_loop() {
  local name="$1"
  local sdir ldir
  sdir=$(machine_dir "$name")
  ldir=$(local_dir "$name")

  local cmd_file="$sdir/cmd"
  local last_job_id=""
  local last_mtime=0
  local last_size=0
  local job_pid=0

  mkdir -p "$sdir/output"
  mkdir -p "$ldir"

  # Read work directory
  local workdir="$REMA_WORKDIR"
  [ -f "$sdir/workdir" ] && workdir=$(cat "$sdir/workdir")

  # Check workdir exists before entering loop
  if [ ! -d "$workdir" ]; then
    echo "worker '$name' aborted: work directory '$workdir' does not exist" >> "$ldir/worker.log"
    echo "off" > "$sdir/status"
    exit 1
  fi

  cd "$workdir"

  # Write crash info on exit
  trap 'echo "worker crashed at $(date "+%Y-%m-%d %H:%M:%S"), exit code: $?" >> "$ldir/worker.log"; echo "off" > "$sdir/status"' EXIT

  while true; do
    # Exit if removed remotely (rm) or locally (stop)
    if [ ! -d "$sdir" ] || [ ! -d "$ldir" ]; then
      [ "$job_pid" -gt 0 ] && kill "$job_pid" 2>/dev/null
      exit 0
    fi

    # Update heartbeat (in shared dir)
    update_heartbeat "$sdir"

    # Check for kill marker
    if [ "$job_pid" -gt 0 ] && [ -f "$sdir/job.kill" ]; then
      rm -f "$sdir/job.kill"
      # Kill the job process (and its children via process group)
      kill "$job_pid" 2>/dev/null
      wait "$job_pid" 2>/dev/null

      local current_job_id
      current_job_id=$(read_cmd_field "$sdir/job" "JOB_ID")
      if [ -n "$current_job_id" ]; then
        {
          echo ""
          echo "=== killed: $(date '+%Y-%m-%d %H:%M:%S') ==="
          echo "REMA_DONE:137"
        } >> "$sdir/output/${current_job_id}.log"
      fi

      rm -f "$sdir/job"
      echo "idle" > "$sdir/status"
      job_pid=0
    fi

    # Check if current job finished
    if [ "$job_pid" -gt 0 ]; then
      if ! kill -0 "$job_pid" 2>/dev/null; then
        # Job process ended, collect exit code
        wait "$job_pid" 2>/dev/null
        local exit_code=$?

        # Find the current job's logfile from the job file
        local current_job_id
        current_job_id=$(read_cmd_field "$sdir/job" "JOB_ID")
        if [ -n "$current_job_id" ]; then
          {
            echo ""
            echo "=== ended: $(date '+%Y-%m-%d %H:%M:%S') ==="
            echo "REMA_DONE:${exit_code}"
          } >> "$sdir/output/${current_job_id}.log"
        fi

        rm -f "$sdir/job"
        echo "idle" > "$sdir/status"
        job_pid=0
      fi
    fi

    # Change detection: compare mtime and size (only when idle)
    if [ "$job_pid" -eq 0 ] && [ -f "$cmd_file" ]; then
      local curr_mtime curr_size
      curr_mtime=$(stat -c%Y "$cmd_file" 2>/dev/null || echo 0)
      curr_size=$(stat -c%s "$cmd_file" 2>/dev/null || echo 0)

      if [ "$curr_mtime" != "$last_mtime" ] || [ "$curr_size" != "$last_size" ]; then
        last_mtime="$curr_mtime"
        last_size="$curr_size"

        local job_id command
        job_id=$(read_cmd_field "$cmd_file" "JOB_ID")
        command=$(read_cmd_field "$cmd_file" "COMMAND")

        if [ -n "$job_id" ] && [ "$job_id" != "$last_job_id" ]; then
          last_job_id="$job_id"

          # Clean old logs before executing
          clean_old_logs "$sdir"

          # Write job info to shared dir
          {
            echo "JOB_ID=${job_id}"
            echo "COMMAND=${command}"
          } > "$sdir/job"

          echo "busy" > "$sdir/status"
          local logfile="$sdir/output/${job_id}.log"

          {
            echo "=== rema job: $job_id ==="
            echo "=== command: $command ==="
            echo "=== started: $(date '+%Y-%m-%d %H:%M:%S') ==="
            echo ""
          } > "$logfile"

          # Execute in background
          bash -c "$command" >> "$logfile" 2>&1 &
          job_pid=$!
        fi
      fi
    fi

    sleep "$REMA_HEARTBEAT_INTERVAL"
  done
}


_worker_loop "$1"
