# ReMA — Remote Machine Access

Execute commands on any machine from anywhere. No network, no SSH — just a shared mount.

## What is ReMA?

ReMA is a lightweight CLI tool that lets you run commands on remote machines through a shared mounted disk. The machines don't need to be connected over the network — they just need to mount the same storage volume (e.g., JuiceFS, NFS, or any shared disk).

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
#    This will create .rema/ in your current directory (e.g., /your/shared/workspace/.rema)
cd /your/shared/workspace
bash install.sh
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
```

**Step 5: Manage machines**
```bash
# List all machines
rema list
# Output:
#   NAME                 STATUS     HEARTBEAT
#   gpu-server           idle       3s ago

# Stop the worker
rema stop gpu-server

# Remove the machine entirely
rema rm gpu-server
```

You can install and start ReMA on as many machines as you want. You can also run multiple workers on the same machine under different names (e.g., `rema start gpu-1` and `rema start gpu-2` on the same host).


## Commands

See [docs/commands.md](docs/commands.md) for the full command reference with examples.


## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `REMA_DIR` | *(required)* | Shared directory path (e.g., `/path/.rema`). Set automatically by `install.sh`. |
| `REMA_LOG_KEEP_DAYS` | `7` | Auto-delete job logs older than N days |

ReMA reads settings from `~/.rema_config`. You can also override them via environment variables. Priority: **environment variable** > `~/.rema_config` > default value.


## Uninstallation

```bash
bash uninstall.sh
```

This will: stop running workers, remove `~/.local/bin/rema` symlink, remove `~/.rema_config`, clean `~/.bashrc`. 

It does **NOT** delete the shared `.rema/` data directory.


## How It Works

See [docs/impl.md](docs/impl.md).
