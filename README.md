# ReMA — Remote Machine Access

Execute commands on any machine from anywhere. No network, no SSH — just a shared mount.

## What is ReMA?

ReMA is a lightweight CLI tool that lets you run commands on remote machines through a shared mounted disk. The machines don't need to be connected over the network — they just need to mount the same storage volume (e.g., JuiceFS, NFS, or any shared disk).

One worker can run multiple commands concurrently. `busy` reports that jobs are
running; it does not prevent submissions. Each job has its own Bash process group,
output log, state, and exit code. Sync and async select how the client waits, not
whether the worker can execute other commands.

Runtime requirements: Linux, Bash 4.4+, GNU core utilities, and `setsid`
(util-linux). Python 3 is needed only for the integration tests.

It works like a simplified SSH replacement for environments where:
- Machines share a disk but can't reach each other over the network
- You want to run commands on a GPU machine from a dev machine
- AI coding agents (Claude Code, Cursor, Copilot) need to execute code on remote hardware

## Installation

```bash
# 1. Clone the repo
git clone https://github.com/Disapole-Xiao/ReMA.git
cd ReMA

# 2. Run installer
bash install.sh
# When prompted, set REMA_DIR to /your/shared/workspace/.rema
```

The installer will:
1. Create `~/.rema_config` with `REMA_DIR=/your/shared/workspace/.rema`
2. Symlink `rema` to `~/.local/bin/rema`
3. Offer to add `source ~/.rema_config` to your `~/.bashrc` (answer `y` to activate automatically in new shells)

After installation, activate:
```bash
source ~/.bashrc
```

If you didn't let the installer add it to `.bashrc`, you can do it manually:
```bash
echo 'source ~/.rema_config' >> ~/.bashrc && source ~/.bashrc
```


## Quick Start

Suppose you have two machines: `dev-machine` (your laptop) and `gpu-server` (with GPUs).

**Step 1: Install ReMA on both machines**

Install ReMA on both machines so they share the same `REMA_DIR` pointing to the shared mount.

**Step 2: On `gpu-server`, start a worker**
```bash
cd /your/project
rema start gpu-server
# Output:
#   rema: worker 'gpu-server' started (pid: 12345)
#   rema: work directory: /your/project
#   rema: log: /tmp/rema/gpu-server/worker.log
```

All subsequent commands will execute in `/your/project` (the directory where you ran `start`).

**Step 3: On `dev-machine`, run commands**
```bash
# Check if the worker is online
rema status gpu-server
# Output: idle

# Run a command (sync mode — real-time output, waits for completion)
rema run gpu-server -- nvidia-smi
# Output: GPU info, streamed in real time

# Run a command in the project directory
rema run gpu-server -- python train.py --lr 0.001

# Run a multi-step command
rema run gpu-server -- "cd src && python preprocess.py && python train.py"
```

**Step 4: Async mode for long-running tasks**
```bash
# Submit and return immediately
rema run gpu-server --async -- python train.py --epochs 100
# Output: rema: job submitted (job_id: 1775844820654_98397_17396)

# Do other work...

# Check the output later (latest job)
rema log gpu-server

# Or check a specific job by ID
rema log gpu-server 1775844820654_98397_17396

# Inspect running jobs, all records, or terminate one specific running job
rema jobs gpu-server
rema jobs gpu-server -a
rema kill gpu-server <job_id>
```

**Step 5: Manage machines**
```bash
# List all machines
rema list
# Output:
#   NAME                 STATUS     RUNNING  HEARTBEAT
#   gpu-server           idle       0        3s ago

# Stop accepting submissions and wait for running jobs to finish (on gpu-server)
rema stop gpu-server

# Or terminate all of this worker's running jobs and stop
rema stop gpu-server -f

# Restart the remote ReMA worker from any client, keeping its working directory
rema restart gpu-server
# Or terminate its tracked jobs before restarting
rema restart gpu-server -f

# Remove the machine entirely
rema rm gpu-server
```

You can install and start ReMA on as many machines as you want. You can also run multiple workers on the same machine under different names (e.g., `rema start gpu-1` and `rema start gpu-2` on the same host).

Each start creates a new session. Only commands submitted to that session are
executed. Old queued commands expire, old incomplete execution records become
`unknown`, and completed jobs are never replayed. Historical logs remain available.
`kill` always requires a job ID; there is no machine-only shorthand.


## Commands

See [docs/commands.md](docs/commands.md) for the full command reference with examples.


## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `REMA_DIR` | *(required)* | Shared directory path (e.g., `/path/.rema`). Set automatically by `install.sh`. |
| `REMA_LOG_KEEP_DAYS` | `7` | Auto-delete job logs older than N days |
| `REMA_LOCAL_DIR` | `/tmp/rema` | Local worker PID and diagnostic log directory |
| `REMA_POLL_INTERVAL` | `5` | Worker loop sleep in seconds; heartbeat updates in the same loop |
| `REMA_OUTPUT_POLL_INTERVAL` | `1` | Client output/control polling interval in seconds |

ReMA reads settings from `~/.rema_config`. You can also override them via environment variables. Priority: **environment variable** > `~/.rema_config` > default value.

Log retention applies only to finished, cancelled, or expired jobs. Running and
unknown job logs are preserved. `rema log <name>` selects the most recently
submitted job, not whichever running job last wrote output.

## Development and upgrades

The concurrent worker uses protocol version 2. After updating the client, use
`rema restart <name>` to load that client's code on the remote worker. This works
with early protocol-2 workers and with legacy workers (graceful upgrade only).
It restarts ReMA, not the host OS, and requires a reachable, running worker.
Working directory and history are preserved; existing commands never replay.
See [restart details](docs/commands.md#restart-and-removal) for configuration and
legacy-client behavior. The remote host's installed CLI is not rewritten.

Develop in the branch and directory requested by the user, with separate worker
names and state directories for tests. Running workers need restart to load
changes; ordinary CLI invocations follow updates to their installed symlink.

Run `bash test_rema.sh` from this checkout. Tests snapshot this checkout's script
and use isolated shared/local directories and worker names, never the installed
`rema` or its registered machines. Set `REMA_TEST_TMPDIR` to choose the test-data
parent directory. The printed test directory is retained for diagnostics.


## Uninstallation

Stop each local worker on its own host with `rema stop <name>` before
uninstalling. Then, from the repository directory, run:

```bash
bash uninstall.sh
```

This removes the `~/.local/bin/rema` symlink and `~/.rema_config`, and cleans
the ReMA shell entries from `~/.bashrc`.

It does **NOT** delete the shared `.rema/` data directory.


## How It Works

See [docs/impl.md](docs/impl.md).
