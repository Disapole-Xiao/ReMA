#!/usr/bin/env python3
"""Behavioral integration tests using isolated workers, directories and processes."""
import concurrent.futures
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SOURCE = Path(sys.argv.pop(1)).resolve()
SUITE = Path(tempfile.mkdtemp(prefix="rema-tests-", dir=os.environ.get("REMA_TEST_TMPDIR")))
# Snapshot the exact checkout once; repeated shell reads on a shared mount are slow.
CLI = SUITE / "rema"
shutil.copy2(SOURCE, CLI)
CLI.chmod(0o755)
LEGACY = SUITE / "legacy-worker.sh"
shutil.copy2(SOURCE.parent / "tests" / "fixtures" / "legacy-worker.sh", LEGACY)
print(f"Isolated test data: {SUITE}", flush=True)


def wait_for(predicate, timeout=15, description="condition"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out waiting for {description}")


def text(path):
    try:
        return path.read_text().strip()
    except FileNotFoundError:
        return ""


def alive(pid):
    try:
        # Zombies have stopped executing even if their parent has not reaped them.
        return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1][0] != "Z"
    except FileNotFoundError:
        return False


class ReMATest(unittest.TestCase):
    def setUp(self):
        self.root = SUITE / self._testMethodName
        self.workdir = self.root / "work dir"
        self.workdir.mkdir(parents=True)
        self.name = "isolated-worker"
        self.sdir = self.root / "shared" / self.name
        self.ldir = self.root / "local" / self.name
        self.env = dict(os.environ, PATH="/usr/bin:/bin", REMA_DIR=str(self.root / "shared"),
                        REMA_LOCAL_DIR=str(self.root / "local"), REMA_POLL_INTERVAL="0.05",
                        REMA_OUTPUT_POLL_INTERVAL="0.05",
                        REMA_KILL_GRACE="1", REMA_CONTROL_TIMEOUT="10",
                        REMA_STATUS_TIMEOUT="10", REMA_OUTPUT_LOG_WAIT="10")
        self.clients = []
        self.groups = set()
        self.previous_failures = len(self._outcome.result.errors) + len(self._outcome.result.failures)
        self.call("start", self.name)

    def tearDown(self):
        try:
            self.call("stop", self.name, "-f", check=False, timeout=15)
        finally:
            for proc in self.clients:
                if proc.poll() is None:
                    proc.terminate()
                proc.wait(timeout=5)
            # Only process groups explicitly created and recorded by this test.
            for pgid in self.groups:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if len(self._outcome.result.errors) + len(self._outcome.result.failures) > self.previous_failures:
            print(f"Worker diagnostics ({self._testMethodName}):\n{text(self.ldir / 'worker.log')}", flush=True)

    def call(self, *args, check=True, timeout=20):
        result = subprocess.run([str(CLI), *args], env=self.env, cwd=self.workdir,
                                capture_output=True, text=True, timeout=timeout)
        if check:
            self.assertEqual(result.returncode, 0, f"{args}\n{result.stdout}\n{result.stderr}")
        return result

    def submit(self, command):
        result = self.call("run", self.name, "--async", "--", command)
        match = re.search(r"job_id: ([^)]+)", result.stdout)
        self.assertIsNotNone(match, result.stdout)
        return match[1]

    def state(self, job):
        return text(self.sdir / "jobs" / job / "state") or text(self.sdir / "pending" / job / "state")

    def wait_state(self, job, state):
        wait_for(lambda: self.state(job) == state, description=f"{job}: {state}")

    def blocked(self, label):
        # Barrier-based tests prove overlap without assuming task duration.
        pidfile = self.workdir / f"{label}.pid"
        gate = self.workdir / f"{label}.release"
        command = (f"echo $$ > {shlex.quote(str(pidfile))}; echo {label}_started; "
                   f"while [ ! -f {shlex.quote(str(gate))} ]; do sleep 0.05; done; echo {label}_done")
        job = self.submit(command)
        self.wait_state(job, "running")
        wait_for(pidfile.exists)
        self.groups.add(int(pidfile.read_text()))
        return job, gate

    def spawn_client(self, *args, output, env=None):
        with output.open("w") as handle:
            proc = subprocess.Popen([str(CLI), *args], env=env or self.env, cwd=self.workdir,
                                    stdout=handle, stderr=subprocess.STDOUT)
        self.clients.append(proc)
        return proc

    def test_lifecycle_and_workdir(self):
        self.assertEqual(self.call("status", self.name).stdout.strip(), "idle")
        self.assertNotEqual(self.call("start", self.name, check=False).returncode, 0)
        self.assertNotEqual(self.call("rm", self.name, check=False).returncode, 0)
        self.assertIn(str(self.workdir), self.call("run", self.name, "--", "pwd").stdout)
        self.assertIn("RUNNING", self.call("list").stdout)
        self.assertIn("JOB_ID", self.call("jobs", self.name).stdout)
        self.call("stop", self.name)
        self.assertEqual(self.call("status", self.name).stdout.strip(), "off")
        self.assertNotEqual(self.call("run", self.name, "--", "echo no", check=False).returncode, 0)
        self.call("rm", self.name)
        self.assertFalse(self.sdir.exists())
        self.assertIn("no machines", self.call("list").stdout)

    def test_busy_accepts_short_job_and_keeps_heartbeat(self):
        long_job, gate = self.blocked("long")
        wait_for(lambda: text(self.sdir / "status") == "busy")
        heartbeat = text(self.sdir / "heartbeat")
        result = self.call("run", self.name, "--", "echo short_job; exit 7", check=False)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("short_job", result.stdout)
        self.assertNotIn("long_started", result.stdout)
        self.assertEqual(self.state(long_job), "running")
        self.assertEqual(self.call("status", self.name).stdout.strip(), "busy")
        wait_for(lambda: text(self.sdir / "heartbeat") != heartbeat, description="heartbeat refresh")
        gate.touch()
        self.wait_state(long_job, "finished")
        wait_for(lambda: text(self.sdir / "status") == "idle")

    def test_concurrent_submissions_are_not_lost_or_repeated(self):
        def submit_one(index):
            return self.submit(f"echo unique_{index}; echo x >> count_{index}; exit {index % 4}")
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            ids = list(pool.map(submit_one, range(12)))
        self.assertEqual(len(set(ids)), 12)
        for index, job in enumerate(ids):
            self.wait_state(job, "finished")
            log = self.call("log", self.name, job).stdout
            tokens = [line for line in log.splitlines() if line.startswith("unique_")]
            self.assertEqual(tokens, [f"unique_{index}"])
            self.assertEqual(text(self.sdir / "jobs" / job / "exit_code"), str(index % 4))
            self.assertEqual((self.workdir / f"count_{index}").read_text(), "x\n")

    def test_sync_streaming_and_exit_markers_are_ordinary_output(self):
        gate = self.workdir / "stream.release"
        output = self.root / "stream.out"
        command = ("printf 'REMA_DONE:0\\n'; echo err_line >&2; printf partial; "
                   f"while [ ! -f {shlex.quote(str(gate))} ]; do sleep 0.05; done; "
                   "printf '_tail\\n'; exit 9")
        client = self.spawn_client("run", self.name, "--", command, output=output)
        wait_for(lambda: "partial" in text(output), description="output before command completes")
        self.assertIsNone(client.poll(), "log marker must not finish the client")
        self.assertEqual(text(output).count("err_line"), 1)
        other = self.call("run", self.name, "--", "echo second_sync")
        self.assertIn("second_sync", other.stdout)
        gate.touch()
        self.assertEqual(client.wait(timeout=15), 9)
        result = output.read_text()
        self.assertEqual(result.count("partial_tail"), 1)
        self.assertEqual(result.count("REMA_DONE:0"), 1)
        self.assertNotIn("second_sync", result)

    def test_kill_requires_id_and_only_stops_target_group(self):
        keep_job, keep_gate = self.blocked("keep")
        parent = self.workdir / "kill-parent.pid"
        child = self.workdir / "kill-child.pid"
        command = (f"echo $$ > {shlex.quote(str(parent))}; "
                   f"sleep 60 & echo $! > {shlex.quote(str(child))}; wait")
        target = self.submit(command)
        self.wait_state(target, "running")
        wait_for(child.exists)
        parent_pid, child_pid = int(parent.read_text()), int(child.read_text())
        self.groups.add(parent_pid)
        self.assertNotEqual(self.call("kill", self.name, check=False).returncode, 0)
        self.assertTrue(alive(parent_pid))
        self.call("kill", self.name, target)
        self.wait_state(target, "cancelled")
        wait_for(lambda: not alive(parent_pid) and not alive(child_pid), description="target process group exit")
        self.assertEqual(self.state(keep_job), "running")
        self.assertEqual(self.call("status", self.name).stdout.strip(), "busy")
        self.assertNotEqual(self.call("kill", self.name, target, check=False).returncode, 0)
        keep_gate.touch()
        self.wait_state(keep_job, "finished")

    def test_graceful_stop_drains_and_rejects_new_jobs(self):
        job, gate = self.blocked("drain")
        stopper = self.spawn_client("stop", self.name, output=self.root / "stop.out")
        wait_for(lambda: (self.sdir / "stop").exists())
        self.assertIsNone(stopper.poll())
        self.assertNotEqual(self.call("run", self.name, "--", "echo rejected", check=False).returncode, 0)
        self.assertEqual(self.state(job), "running")
        gate.touch()
        self.assertEqual(stopper.wait(timeout=15), 0, text(self.root / "stop.out"))
        self.assertEqual(self.state(job), "finished")
        self.assertEqual(self.call("status", self.name).stdout.strip(), "off")

    def test_force_stop_escalates_and_does_not_touch_other_processes(self):
        jobs = []
        for index in range(2):
            pidfile = self.workdir / f"force-{index}.pid"
            command = (f"trap '' TERM; echo $$ > {shlex.quote(str(pidfile))}; "
                       "while :; do sleep 1; done")
            job = self.submit(command)
            self.wait_state(job, "running")
            wait_for(pidfile.exists)
            self.groups.add(int(pidfile.read_text()))
            jobs.append(job)
        unrelated = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            # A second stop -f must also be able to interrupt an existing drain.
            drainer = self.spawn_client("stop", self.name, output=self.root / "drain.out")
            wait_for(lambda: (self.sdir / "stop").exists())
            self.call("stop", self.name, "-f")
            self.assertEqual(drainer.wait(timeout=10), 0, text(self.root / "drain.out"))
            self.assertIsNone(unrelated.poll())
            for job in jobs:
                self.assertEqual(self.state(job), "cancelled")
            for pid in self.groups:
                wait_for(lambda pid=pid: not alive(pid), description="force-stopped group leader")
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_restart_ignores_all_previous_work_including_late_requests(self):
        done = self.submit("echo x >> once")
        self.wait_state(done, "finished")
        old_session = text(self.sdir / "session")
        self.call("stop", self.name)
        def old_job(base, name, state):
            directory = self.sdir / base / name
            directory.mkdir()
            (directory / "command.sh").write_text("echo BAD >> replayed\n")
            (directory / "session").write_text(old_session + "\n")
            (directory / "state").write_text(state + "\n")
        old_job("pending", "old-queued", "queued")
        old_job("jobs", "old-running", "running")
        # A crash can occur between publishing exit_code and terminal state.
        (self.sdir / "jobs" / "old-running" / "exit_code").write_text("0\n")
        # The legacy single-slot request must also never be replayed.
        (self.sdir / "cmd").write_text("JOB_ID=legacy\nCOMMAND=echo BAD >> replayed\n")
        self.call("start", self.name)
        self.assertNotEqual(text(self.sdir / "session"), old_session)
        self.assertEqual(self.state("old-queued"), "expired")
        self.assertEqual(self.state("old-running"), "unknown")
        self.assertFalse((self.sdir / "jobs" / "old-running" / "exit_code").exists())
        old_job("pending", "late-old-request", "queued")
        self.wait_state("late-old-request", "expired")
        self.call("run", self.name, "--", "echo fresh")
        self.assertFalse((self.workdir / "replayed").exists())
        self.assertEqual((self.workdir / "once").read_text(), "x\n")
        self.assertIn("rema job", self.call("log", self.name, done).stdout)

    def test_remote_restart_drains_preserves_workdir_and_explicit_environment(self):
        job, gate = self.blocked("restart-drain")
        old_session = text(self.sdir / "session")
        # The submitting host has no access to the target's local PID directory.
        remote_env = dict(self.env, REMA_LOCAL_DIR=str(self.root / "client-local"),
                          REMA_POLL_INTERVAL="9")
        output = self.root / "restart.out"
        client = self.spawn_client("restart", self.name, output=output, env=remote_env)
        wait_for(lambda: (self.sdir / "stop").exists())
        self.assertIsNone(client.poll(), text(output))
        self.assertEqual(self.state(job), "running")
        self.assertNotEqual(self.call("run", self.name, "--", "echo rejected", check=False).returncode, 0)
        self.assertNotEqual(self.call("start", self.name, check=False).returncode, 0)
        gate.touch()
        self.assertEqual(client.wait(timeout=15), 0, text(output))
        self.assertNotEqual(text(self.sdir / "session"), old_session)
        self.assertEqual(self.state(job), "finished")
        self.assertEqual(text(self.sdir / "poll_interval"), "0.05")
        self.assertEqual(text(self.sdir / "workdir"), str(self.workdir))
        self.assertIn(str(self.workdir), self.call("run", self.name, "--", "pwd").stdout)
        self.assertFalse((self.sdir / "restart.lock").exists())

    def test_remote_restart_force_escalates_one_request_and_preserves_other_processes(self):
        jobs = [self.blocked(f"restart-force-{i}")[0] for i in range(2)]
        old_pid = int(text(self.ldir / "pid"))
        unrelated = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            output = self.root / "restart-drain.out"
            client = self.spawn_client("restart", self.name, output=output)
            wait_for(lambda: (self.sdir / "stop").exists())
            result = self.call("restart", self.name, "-f")
            self.assertEqual(client.wait(timeout=15), 0, text(output))
            self.assertEqual(len(list((self.sdir / "restarts").iterdir())), 1)
            self.assertIn("restarted", result.stdout)
            self.assertFalse(alive(old_pid))
            self.assertIsNone(unrelated.poll())
            for job in jobs:
                self.assertEqual(self.state(job), "cancelled")
            for pid in self.groups:
                self.assertFalse(alive(pid))
            self.call("run", self.name, "--", "echo after_restart")
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_remote_upgrade_reloads_new_defaults_and_rejects_offline_restart(self):
        # Early protocol-2 workers exported resolved defaults without provenance.
        # Removing this new metadata simulates that earlier launch environment.
        shutil.rmtree(self.ldir / "environments")
        self.call("restart", self.name)
        self.assertEqual(text(self.sdir / "poll_interval"), "5")
        self.call("stop", self.name)
        result = self.call("restart", self.name, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("offline", result.stderr)

    def test_remote_restart_reports_bootstrap_failure_without_stopping_worker(self):
        old_pid = text(self.ldir / "pid")
        # An unrelated/stale PID file must not permit signalling another process.
        (self.ldir / "pid").write_text(str(os.getpid()))
        try:
            result = self.call("restart", self.name, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.sdir / "restart.lock").exists())
            self.assertTrue(alive(int(old_pid)))
        finally:
            (self.ldir / "pid").write_text(old_pid)

    def test_remote_restart_tolerates_temporarily_unreadable_progress(self):
        job, gate = self.blocked("restart-visibility")
        output = self.root / "restart-visibility.out"
        client = self.spawn_client("restart", self.name, output=output)
        wait_for(lambda: (self.sdir / "stop").exists())
        request = self.sdir / "restarts" / text(self.sdir / "restart.lock" / "request")
        state = request / "state"
        hidden = request / "hidden-state"
        state.rename(hidden)
        try:
            time.sleep(0.3)  # Several client polls with a missing remote record.
            self.assertIsNone(client.poll(), text(output))
        finally:
            hidden.rename(state)
        gate.touch()
        self.assertEqual(client.wait(timeout=15), 0, text(output))
        self.assertEqual(self.state(job), "finished")

    def test_remote_restart_survives_client_disconnect_after_handoff(self):
        job, gate = self.blocked("restart-disconnect")
        old_session = text(self.sdir / "session")
        client = self.spawn_client("restart", self.name, output=self.root / "restart-disconnect.out")
        wait_for(lambda: (self.sdir / "stop").exists())
        client.terminate()
        client.wait(timeout=5)
        gate.touch()
        wait_for(lambda: text(self.sdir / "session") != old_session and
                 not (self.sdir / "restart.lock").exists(), description="detached restart completion")
        self.assertEqual(self.state(job), "finished")
        self.call("run", self.name, "--", "echo after_disconnect")

    def test_remote_restart_upgrades_actual_legacy_worker_without_losing_pending_job(self):
        self.call("stop", self.name)
        for field in ("protocol", "session", "version", "accepting"):
            (self.sdir / field).unlink(missing_ok=True)
        (self.ldir / "session").unlink(missing_ok=True)
        shutil.rmtree(self.ldir / "environments")
        gate = self.workdir / "legacy.release"
        command = f"echo legacy_started; while [ ! -f {shlex.quote(str(gate))} ]; do sleep 0.05; done; echo x >> legacy-count"
        # A request may already be pending when restart is submitted.
        (self.sdir / "cmd").write_text(f"JOB_ID=legacy-existing\nCOMMAND={command}\n")
        with (self.ldir / "worker.log").open("a") as log:
            legacy = subprocess.Popen(["bash", str(LEGACY), self.name], env=self.env,
                                      cwd=self.workdir, stdin=subprocess.DEVNULL,
                                      stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.clients.append(legacy)
        self.groups.add(legacy.pid)
        (self.ldir / "pid").write_text(str(legacy.pid))
        wait_for(lambda: text(self.sdir / "status") == "busy")
        result = self.call("restart", self.name, "-f", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("only graceful", result.stderr)
        self.assertFalse((self.sdir / "restart.lock").exists())
        output = self.root / "legacy-restart.out"
        remote_env = dict(self.env, REMA_LOCAL_DIR=str(self.root / "client-local"))
        client = self.spawn_client("restart", self.name, output=output, env=remote_env)
        wait_for(lambda: (self.sdir / "restart.lock").exists())
        self.assertIn("JOB_ID=legacy-existing", text(self.sdir / "cmd"))
        self.assertIsNone(client.poll())
        gate.touch()
        self.assertEqual(client.wait(timeout=25), 0, text(output))
        legacy.wait(timeout=10)
        self.assertEqual(text(self.sdir / "protocol"), "2")
        self.assertEqual(text(self.sdir / "poll_interval"), "5")
        self.assertEqual(text(self.sdir / "workdir"), str(self.workdir))
        self.call("run", self.name, "--", "echo upgraded")
        self.assertEqual((self.workdir / "legacy-count").read_text(), "x\n")
        self.assertIn("REMA_DONE:0", self.call("log", self.name, "legacy-existing").stdout)

    def test_worker_crash_unblocks_client_without_replaying_or_killing_old_job(self):
        # This client's shorter timeout only changes how quickly it detects loss.
        self.env["REMA_STATUS_TIMEOUT"] = "1"
        pidfile = self.workdir / "orphan.pid"
        gate = self.workdir / "orphan.release"
        output = self.root / "crash-client.out"
        command = (f"echo $$ > {shlex.quote(str(pidfile))}; echo x >> attempts; "
                   f"while [ ! -f {shlex.quote(str(gate))} ]; do sleep 0.05; done")
        client = self.spawn_client("run", self.name, "--", command, output=output)
        wait_for(pidfile.exists)
        job_pid = int(pidfile.read_text())
        self.groups.add(job_pid)
        job = re.search(r"job_id: ([^)]+)", text(output))[1]
        self.wait_state(job, "running")
        worker_pid = int(text(self.ldir / "pid"))
        os.kill(worker_pid, signal.SIGKILL)
        self.assertEqual(client.wait(timeout=10), 125)
        self.assertIn("outcome unknown", text(output))
        self.assertTrue(alive(job_pid), "restart must not implicitly terminate earlier tasks")
        self.call("start", self.name)
        self.assertEqual(self.state(job), "unknown")
        self.call("run", self.name, "--", "echo new_session")
        self.assertEqual((self.workdir / "attempts").read_text(), "x\n")
        gate.touch()
        wait_for(lambda: not alive(job_pid), description="old task finishes normally")

    def test_latest_log_and_multiline_command(self):
        old, gate = self.blocked("old")
        latest = self.submit("echo line_one\necho line_two\n")
        self.wait_state(latest, "finished")
        gate.touch()
        self.wait_state(old, "finished")
        result = self.call("log", self.name).stdout
        self.assertIn("line_one\nline_two", result)
        self.assertNotIn("old_done", result)

    def test_protocol_mismatch_is_read_only(self):
        self.call("stop", self.name)
        # Simulate a live old-protocol worker without starting any old processes.
        (self.sdir / "protocol").unlink()
        (self.sdir / "status").write_text("idle\n")
        (self.sdir / "heartbeat").write_text(f"{int(time.time())}\n")
        sentinel = self.sdir / "cmd"
        sentinel.write_text("do not overwrite\n")
        result = self.call("run", self.name, "--", "echo no", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incompatible worker protocol", result.stderr)
        self.assertEqual(sentinel.read_text(), "do not overwrite\n")
        (self.sdir / "status").write_text("off\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
