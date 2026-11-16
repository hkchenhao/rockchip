"""Integration checks using a simulated board on a local PTY."""

import json
import os
from pathlib import Path
import pty
import select
import socket
import subprocess
import sys
import tempfile
import time
import tty
import unittest

import serial


BRIDGE = Path(__file__).resolve().parent / "serial_bridge.py"


def read_fd(fd, expected, timeout=3):
    data = b""
    deadline = time.monotonic() + timeout
    while expected not in data and time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            data += os.read(fd, 65536)
    return data


class SerialBridgeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="serial-bridge-test-")
        self.addCleanup(self.directory.cleanup)
        self.master, self.slave = pty.openpty()
        self.addCleanup(os.close, self.master)
        self.addCleanup(os.close, self.slave)
        tty.setraw(self.slave)
        self.process = subprocess.Popen(
            [sys.executable, str(BRIDGE), "--port", os.ttyname(self.slave),
             "--baud", "115200", "--runtime", self.directory.name],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.stop)
        ready, _, _ = select.select([self.process.stdout], [], [], 5)
        self.assertTrue(ready, "bridge did not report readiness")
        line = self.process.stdout.readline()
        self.assertTrue(line, self.process.stderr.read() if self.process.poll() is not None else "bridge exited")
        self.info = json.loads(line)
        self.user = serial.Serial(self.info["user_port"], 115200, timeout=0.2)
        self.addCleanup(self.user.close)
        self.agent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(self.agent.close)
        self.agent.connect(self.info["agent_socket"])

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()

    def test_broadcast_and_both_input_paths(self):
        os.write(self.master, b"board output\r\n")
        self.assertIn(b"board output\r\n", read_fd(self.user.fileno(), b"board output\r\n"))
        self.assertIn(b"board output\r\n", read_fd(self.agent.fileno(), b"board output\r\n"))
        self.user.write(b"user command\r")
        self.assertEqual(read_fd(self.master, b"user command\r"), b"user command\r")
        self.agent.sendall(b"agent command\r")
        self.assertEqual(read_fd(self.master, b"agent command\r"), b"agent command\r")
        self.assertFalse(select.select([self.master], [], [], 0.2)[0], "PTY echoed board output back to the board")

    def test_user_reconnect_and_agent_disconnect(self):
        self.user.close()
        self.user.open()
        self.agent.close()
        os.write(self.master, b"still running\r\n")
        self.assertIn(b"still running\r\n", read_fd(self.user.fileno(), b"still running\r\n"))
        self.user.write(b"after reconnect\r")
        self.assertEqual(read_fd(self.master, b"after reconnect\r"), b"after reconnect\r")
        self.assertIsNone(self.process.poll())

    def test_socket_is_private_and_cleanup_removes_endpoints(self):
        self.assertEqual(os.stat(self.info["agent_socket"]).st_mode & 0o777, 0o600)
        self.process.terminate()
        self.process.wait(timeout=5)
        self.assertFalse(os.path.lexists(self.info["user_port"]))
        self.assertFalse(os.path.exists(self.info["agent_socket"]))


if __name__ == "__main__":
    unittest.main()
