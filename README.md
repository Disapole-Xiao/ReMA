# ReMA — Remote Machine Access

Execute commands across machines through a shared mount. No network between machines needed.

## Motivation

In research labs and corporate environments, machines often mount a shared data volume but cannot reach each other over the network. Meanwhile, each machine may have different hardware configurations (e.g., different GPU types), and experiment environments are scattered across Docker containers on various hosts.

**ReMA** solves this by letting you develop on one machine and run code on any other machine — all through the shared mount. It's especially useful with AI coding agents like Claude Code, Cursor, and Copilot, which can automatically run tests, debug, and iterate on remote machines with real-time feedback, without any SSH or network setup.

## Installation

```bash
# From the directory where you want .rema/ to live
cd /path/to/shared/workspace
bash install.sh
```

The installer will:
1. Default `REMA_DIR` to `$(pwd)/.rema` — run from the directory you want as your shared workspace root
2. Write the config to `~/.rema_config`
3. Symlink `rema` to `~/.local/bin/rema`
4. Offer to add `source ~/.rema_config` to your `~/.bashrc`

After installation, activate in current shell:
```bash
source ~/.rema_config && source ~/.bashrc
```

Or just copy this one-liner to activate immediately:
```bash
echo 'source ~/.rema_config' >> ~/.bashrc && source ~/.bashrc
```

## Uninstallation

```bash
bash uninstall.sh
```

Stops running workers, removes symlink, removes config, cleans `~/.bashrc`. Does **not** delete the shared `.rema/` data directory.

## Quick Start

```bash
# Machine B: start worker (commands execute in the directory where you run start)
rema start gpu-b

# Machine A: execute command
rema run gpu-b -- nvidia-smi

# Check status
rema status gpu-b

# Async mode
rema run gpu-b --async -- sleep 10
rema log gpu-b

# Stop worker
rema stop gpu-b
```

## Commands

| Command | Description |
|---------|-------------|
| `rema start <name>` | Start worker on this machine |
| `rema stop <name>` | Stop worker |
| `rema status <name>` | Check status: idle / busy / off |
| `rema run <name> -- <cmd>` | Execute command (sync, real-time output) |
| `rema run <name> --async -- <cmd>` | Execute command (async, returns immediately) |
| `rema log <name> [job_id]` | View job output |
| `rema list` | List all machines and status |
| `rema rm <name>` | Remove a machine and its data |

## How It Works

```
Machine A (submit)         Shared Mount              Machine B (worker)
rema run gpu-b -- cmd  --> $REMA_DIR/gpu-b/cmd   --> _worker_loop
                                           log file <--  output
```

- All communication through the shared mount (no network required)
- Worker polls cmd file using mtime+size change detection
- Jobs execute in the directory where `rema start` was run
- Each log ends with `REMA_DONE:<exit_code>` marker

## Configuration

Set via environment variable or `~/.rema_config`:

| Variable | Default | Description |
|----------|---------|-------------|
| `REMA_DIR` | *(required)* | Shared directory path (where `.rema/` lives) |
| `REMA_LOG_KEEP_DAYS` | `7` | Auto-delete logs older than N days |

## File Layout

Shared mount (cross-machine communication):
```
$REMA_DIR/
  <name>/
    registered   # Machine registration marker
    cmd          # Pending command (key=value format)
    status       # idle / busy / off
    heartbeat    # Worker heartbeat (epoch seconds)
    workdir      # Working directory for commands
    output/
      *.log      # Job output files
```

Local state (`/tmp/rema/`, per-machine, cleared on reboot):
```
/tmp/rema/
  <name>/
    pid          # Worker process ID
    worker.log   # Worker process log (crash info, etc.)
```
