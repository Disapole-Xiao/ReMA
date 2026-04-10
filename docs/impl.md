# How It Works

```
Machine A (submit)           Shared Mount               Machine B (worker)
                             (JuiceFS / NFS / etc.)

rema run gpu-b -- cmd   -->  $REMA_DIR/gpu-b/cmd    -->  worker detects new cmd
                                                          executes command
rema: real-time output  <--  $REMA_DIR/gpu-b/output/  <-- writes output to log
```

All communication happens by reading and writing files on the shared mount. No network packets, no SSH tunnels.

- Worker polls the `cmd` file every 5 seconds using mtime+size change detection
- Each job gets a unique ID and writes output to `$REMA_DIR/<name>/output/<job_id>.log`
- Sync mode tails the log file in real time; async mode returns immediately


## File Layout

Shared mount (visible to all machines):
```
$REMA_DIR/
  <name>/
    status        # idle / busy / off
    heartbeat     # last heartbeat timestamp (epoch seconds)
    cmd           # current command (key=value format)
    workdir       # working directory for commands
    output/
      *.log       # per-job output logs
```

Local state (per-machine, in `/tmp/rema/`, cleared on reboot):
```
/tmp/rema/
  <name>/
    pid           # worker process ID
    worker.log    # worker process log (crash info, errors)
```

Only `pid` and `worker.log` are local — everything else is on the shared mount so that any machine can check status, submit commands, and read output.

