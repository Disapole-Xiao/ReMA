# Commands Reference

## `rema start <name>`

Start a worker on the current machine. The current directory becomes the working directory for all commands.

```bash
cd /your/project
rema start gpu-server
```

The worker runs in the background, polling for new commands every 5 seconds.

## `rema stop <name>`

Stop a running worker on the current machine.

```bash
rema stop gpu-server
```

## `rema status <name>`

Check a machine's status. Works from any machine.

```bash
rema status gpu-server
# idle / busy / off
```

- **idle** — Worker is running, ready for commands
- **busy** — Worker is executing a command
- **off** — Worker is not running or heartbeat expired (60s timeout)

## `rema run <name> [--async] -- <command>`

Execute a command on a remote machine.

- **Sync mode** (default): streams output to your terminal in real time. Returns when the command finishes, with the same exit code.
- **Async mode** (`--async`): submits the command and returns immediately with a job ID. Use `rema log` to retrieve output later.

```bash
# Sync — real-time output, waits for completion
rema run gpu-server -- nvidia-smi
rema run gpu-server -- python train.py --lr 0.001
rema run gpu-server -- "cd src && python preprocess.py && python train.py"

# Sync — check exit code (same as command's exit code)
rema run gpu-server -- python test.py
echo $?

# Async — returns immediately
rema run gpu-server --async -- python train.py --epochs 100
# Output: rema: job submitted (job_id: 1775844820654_98397_17396)

# Retrieve output later
rema log gpu-server                              # latest job
rema log gpu-server 1775844820654_98397_17396    # specific job
```

## `rema log <name> [job_id]`

View job output. Without `job_id`, shows the most recent job.

```bash
rema log gpu-server                              # latest job
rema log gpu-server 1775844820654_98397_17396    # specific job
```

## `rema list`

List all registered machines and their status.

```bash
rema list
#   NAME                 STATUS     HEARTBEAT
#   gpu-server           idle       3s ago
#   gpu-b                busy       12s ago
#   test-machine         off        5m ago
```

## `rema rm <name>`

Remove a machine. Only works when the machine is **off**. If idle or busy, stop it first.

```bash
rema stop gpu-server && rema rm gpu-server   # running
rema rm gpu-server                           # already off
```
