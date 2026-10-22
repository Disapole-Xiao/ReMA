# Commands Reference

| Command | Behavior |
| --- | --- |
| `rema start <name>` | Start a worker on this host, using the current working directory |
| `rema stop <name>` | Stop accepting submissions, wait for running jobs, then exit |
| `rema stop <name> -f` | Terminate all jobs owned by this worker, then exit |
| `rema restart <name> [-f]` | Restart the remote worker in its original directory; drain jobs, or terminate them with `-f` |
| `rema status <name>` | Print `idle`, `busy`, or `off` |
| `rema run <name> -- <command>` | Submit, follow that job's output, and return its exit code |
| `rema run <name> --async -- <command>` | Submit and return its job ID immediately |
| `rema jobs <name>` | List only jobs in the `running` state |
| `rema jobs <name> -a` | List all jobs, including queued jobs and retained history (`--all` also works) |
| `rema log <name> [job_id]` | Read the specified job's log, or the latest submitted job's log |
| `rema kill <name> <job_id>` | Terminate one running job; the job ID is mandatory |
| `rema list` | List workers, status, running counts, and heartbeat age |
| `rema rm <name>` | Delete an off worker's shared records and logs |
| `rema -h` / `rema --help` | Show help |
| `rema -V` / `rema --version` | Show version |

## Concurrent execution

Both `idle` and `busy` workers accept submissions. Each command runs in a separate
Bash process group, beginning in the directory where `start` was run. Commands
share the host's CPU, GPU, filesystem, and inherited environment; ReMA does not
allocate or isolate these resources and does not impose a concurrency limit.

```bash
rema run gpu-server --async -- 'python -u train.py'
# This runs alongside training, even though the worker is busy.
rema run gpu-server -- nvidia-smi
rema jobs gpu-server
```

Quote composite or multiline shell commands as one argument. Each job runs with
stdin disconnected; this is command execution, not an interactive terminal.
Sync clients print their job ID to stderr immediately, follow output at the poll
interval (default one second), and return the command's exit code. Program output
buffering still applies, for example use Python's `-u` for prompt output.
Interrupting a sync client does not cancel its submitted job; use `kill` explicitly.

Async success means the request was published, not that execution has completed
or even started. Inspect `jobs -a` and `log` for the outcome. If a worker disappears
or restarts before a sync client observes completion, the client returns 125 with
the job ID and an unknown-outcome message. A timeout waiting for a job to start
also returns 125; it does not undo the submission.

## Task states

| State | Meaning |
| --- | --- |
| `queued` | Published for the current session, awaiting dispatch |
| `running` | Started; the worker has not yet collected its exit code |
| `finished` | Completed; inspect the exit code (zero or nonzero) |
| `cancelled` | Terminated on request, or not started because the worker is stopping |
| `expired` | Submitted to an old session; will never execute |
| `unknown` | Left incomplete by an earlier worker; outcome cannot be confirmed |

`jobs` shows only `running` tasks. Use `rema jobs <name> -a` to include queued,
finished, cancelled, expired, and unknown records. `log` without an ID selects the
latest submission; a queued job may not have output yet. A retained record can
outlive its log under the retention policy.

## Stop and kill

`start` and `stop` run on the worker host. Ordinary `stop` closes submissions
immediately and waits for running jobs without a fixed completion deadline.
Requests not yet started are cancelled. The status remains `busy` while jobs
drain, then becomes `off`. A separate `stop <name> -f` can escalate an ongoing drain.

`kill` works from any host sharing the storage and requires an explicit, running
job ID in the current session. It never chooses a job automatically. It waits
for that task's cancellation, regardless of other jobs remaining busy. A job that
finishes before the cancellation is applied is reported as already finished,
rather than falsely reported as killed.

Termination sends SIGTERM to the job's independent process group and escalates to
SIGKILL if necessary (default five seconds). Other jobs, workers, and unrelated
host processes are not targeted. Descendants that deliberately detach into new
sessions/process groups are outside this mechanism; do not daemonize work that
ReMA should manage. `-f` does not affect any other worker's jobs.

## Restart and removal

`rema restart <name>` works from any client with access to the shared directory.
It restarts the remote **ReMA worker**, not the operating system. The worker must
still be online; an offline host cannot receive a restart through shared files.
New submissions close during restart. Running jobs finish before the replacement
starts, in the original working directory. `restart <name> -f` terminates that
worker's tracked jobs first. Another `restart -f` can escalate a graceful restart;
concurrent callers join the same request instead of starting duplicate workers.

Restart stages the calling CLI's code on shared storage, then uses a detached
helper on the target host. This also upgrades workers that predate the restart
command. It leaves the target host's installed CLI path unchanged. The helper
waits for its bootstrap job to finish before draining, avoiding self-deadlock.
Invoke restart directly from your client, not through the target's `rema run`.
Once published, a restart continues if its client disconnects. The printed
request directory retains progress, helper output (`log`), and the bootstrap
job ID. On failure inspect those logs; do not blindly remove a restart lock.

The replacement reloads current defaults and the target's `~/.rema_config`.
Explicit ReMA environment overrides recorded at `start` are preserved; other
inherited environment variables remain available. Workers launched before override
recording reload ReMA settings from config/defaults on their first upgrade, so
persist any shell-only custom settings in the target config beforehand.

Legacy protocol-1 workers support a graceful first upgrade only; `-f` is rejected.
Existing submitted work finishes before the bootstrap replaces their single-slot
request. Stop submissions from old clients during migration: they cannot observe
the new restart lock. The helper verifies the exact worker PID and ancestry,
then stops only an idle legacy dispatcher. Normal `run` still requires protocol 2.

Every `start` establishes a new session. Old pending requests, including requests
from an old client that arrive after restart, are expired. Old incomplete job
records become `unknown`; they are not resumed or rerun. Completed commands and
the old protocol's `cmd` file are never replayed. Historical logs remain readable.

An uncatchable worker failure (SIGKILL or host failure) can leave command processes
alive. `off` describes the worker's availability, not proof that all host processes
have stopped. Restart does not automatically adopt or kill those old processes.

`rm` requires `off` and removes shared machine metadata and job logs. There is no
force-remove option for online workers.

## Configuration

Environment variables override `~/.rema_config`, which overrides defaults.

| Variable | Default | Purpose |
| --- | --- | --- |
| `REMA_DIR` | required | Absolute shared state directory |
| `REMA_LOCAL_DIR` | `/tmp/rema` | Absolute local PID/session/worker-log directory |
| `REMA_LOG_KEEP_DAYS` | `7` | Retention for terminal job logs, excluding `unknown` |
| `REMA_POLL_INTERVAL` | `5` | Worker loop sleep in seconds; heartbeat updates in the same loop |
| `REMA_OUTPUT_POLL_INTERVAL` | `1` | Client output/control polling interval in seconds |
| `REMA_STATUS_TIMEOUT` | `60` | Maximum heartbeat age before reporting `off` |
| `REMA_OUTPUT_LOG_WAIT` | `30` | Startup and initial job-output timeout in seconds |
| `REMA_CONTROL_TIMEOUT` | `30` | Timeout waiting for a targeted cancellation |
| `REMA_KILL_GRACE` | `5` | Seconds before escalating a termination to SIGKILL |

Heartbeats update synchronously on each worker-loop iteration. There is no
separate heartbeat process or timer. Status and task counts reflect the latest
poll; they are observations rather than submission locks.
