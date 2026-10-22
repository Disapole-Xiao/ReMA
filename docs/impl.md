# How It Works

ReMA uses one dispatcher per worker name. The dispatcher launches each accepted
command in an independent `setsid bash` process group, tracks job IDs and PIDs in
Bash associative arrays, and reaps completed jobs without blocking other work.

```text
Client(s)                  Shared mount                    Worker
write complete request -> pending/<job_id>/        -> claim by atomic rename
                           jobs/<job_id>/command.sh -> independent Bash per job
follow own output      <- output/<job_id>.log      <- stdout + stderr
read own result        <- jobs/<job_id>/state      <- per-job exit status
```

## File layout (protocol 2)

```text
$REMA_DIR/<name>/
  protocol               # 2; client refuses incompatible workers
  version                # version of the running worker
  poll_interval          # actual configured worker loop sleep
  session                # unique ID for this worker invocation
  accepting              # current session while submissions are open
  status                 # idle / busy / off
  running                # current tracked job count
  heartbeat              # epoch seconds, updated in the dispatcher loop
  workdir                # absolute working directory captured at start
  start.lock/            # serializes startup, removed after readiness
  restart.lock/request   # active restart request ID; closes submissions
  restarts/<request_id>/  # staged script, progress, helper log, bootstrap job ID
  stop                   # optional session-scoped graceful stop request
  force-stop             # optional session-scoped force stop request
  .submit.<random>/       # unpublished request staging directory
  pending/<job_id>/
    command.sh           # full command, including embedded newlines
    session              # session captured by the submitting client
    state                # queued
  jobs/<job_id>/          # claimed requests and retained job history
    command.sh
    session
    state                # running / finished / cancelled / expired / unknown
    exit_code            # published before terminal state, when known
    reason               # optional explanation for cancellation/expiry/unknown
    kill                 # optional per-job cancellation request
  output/<job_id>.log

$REMA_LOCAL_DIR/<name>/   # default: /tmp/rema/<name>/, on the worker host
  pid
  session
  worker.log
  environments/<session>/ # explicit ReMA overrides recorded at start
```

## Publication and dispatch

The client captures the active session and checks that the worker accepts jobs.
It writes a complete private staging directory, rechecks acceptance, then renames
it into `pending/` on the same filesystem. IDs include a timestamp, PID, random
components, and the staging directory's unique suffix. Multiple clients never
write the same request or output file. The worker moves a published request into
`jobs/` before launching it. No mtime/size deduplication or single command slot is
used. This relies on the shared filesystem providing atomic same-filesystem
renames and normal cross-host visibility; polling latency follows that storage.

The loop updates the heartbeat, processes cancellation/completion, dispatches new
requests, and publishes the aggregate running count and status. Each iteration
sleeps for `REMA_POLL_INTERVAL` (five seconds by default). Only the dispatcher writes
aggregate status: one job finishing cannot make the worker idle while others run.
Client output/control polling uses `REMA_OUTPUT_POLL_INTERVAL` (one second).

The count covers commands whose Bash process has not yet been reaped. Commands
must wait for work they intend ReMA to track. Backgrounding and detaching processes
inside a command is not a persistent-service management mechanism.

## Results and cancellation

Output is separate from completion metadata. A command printing `REMA_DONE:0`
does not finish a client. Sync clients track byte offsets and read bounded chunks,
so partial lines and concurrent appends are not duplicated. After observing a
terminal state, they drain the final log bytes and return the saved exit code.

`kill <name> <job_id>` writes only that job's cancellation marker. The dispatcher
signals only its recorded process group, escalates if necessary, reaps the root
process, and publishes the result. `stop -f` applies this to all owned job groups;
ordinary `stop` closes submissions and waits. Separate stop markers make escalation
monotonic even if graceful and force-stop clients overlap. Worker signal/exit
cleanup also terminates its tracked jobs; SIGKILL cannot run cleanup handlers.

Terminal metadata and shared status use temporary files plus atomic rename.
The job's `exit_code` is published before its terminal `state`. Running and unknown
logs are excluded from automatic cleanup; terminal log pruning runs in the worker
loop at startup and hourly, independently of job submission volume.

## Session boundaries and failures

Startup creates a new session and expires earlier queued requests. Earlier
incomplete claimed requests become `unknown`. Requests that arrive late are
checked against the active session on every dispatch and expire if mismatched.
Nothing from an earlier session is automatically executed, including old `cmd`
files. A crash between claim and execution can leave an unknown outcome; the
system deliberately does not replay it or promise exactly-once external effects.

Startup is serialized with an atomic directory lock and checks both local PID
and shared heartbeat. If a startup client is killed with SIGKILL before releasing
`start.lock`, an operator must verify no startup is active before removing that
specific stale lock. Names must be unique across hosts sharing `REMA_DIR`.

Normal submissions refuse protocol-1 workers. Remote restart uses a bootstrap job
under the currently running protocol, so an older worker can hand off to a new
one without already implementing restart. The client stages its exact script;
the target launches a detached helper, verifies local PID/ancestry/start time,
waits for the bootstrap to be reaped, and drains/stops before starting a replacement.
The replacement uses that script snapshot, the original working directory, and
saved explicit configuration overrides. Older workers without override metadata
reload ReMA settings from target config/defaults instead of retaining old defaults.

An atomic `restart.lock` serializes requests and blocks new submissions/start/rm.
Concurrent restart callers join the same request; `-f` is a monotonic escalation.
Legacy workers support graceful migration only; the helper pauses an idle
dispatcher to verify no job is active before signalling that exact PID. Old
clients must stop submitting during migration because they do not honor the lock.
Restart snapshots and request diagnostics are retained. A helper crash can leave
a lock: verify no helper or startup remains active before removing that exact
lock. Offline workers require host access; a shared-file request cannot revive them.
