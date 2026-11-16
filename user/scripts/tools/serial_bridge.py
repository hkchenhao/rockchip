#!/usr/bin/env python3
"""Share one physical serial port with a terminal PTY and local socket clients.

Requires pyserial. The physical baud rate is set here; a client opening user.tty
can use a standard baud rate such as 115200 because PTYs do not carry a clock.
All input goes to the same board console, so clients must take turns typing.
"""

import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import sys
import tty

import serial


MAX_PENDING = 2 * 1024 * 1024


def serve(port, baud, runtime):
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(runtime, 0o700)
    user_port = runtime / "user.tty"
    agent_socket = runtime / "agent.sock"
    clients = {}
    pending = {}
    created_paths = []
    master = slave = None
    running = True

    def stop(signum, frame):
        nonlocal running
        running = False

    def disconnect(fd):
        client = clients.pop(fd, None)
        pending.pop(fd, None)
        if client is not None:
            client.close()

    def enqueue(fd, data):
        buffer = pending.setdefault(fd, bytearray())
        if len(buffer) + len(data) > MAX_PENDING:
            if fd in clients:
                print("Disconnecting slow socket reader", file=sys.stderr, flush=True)
                disconnect(fd)
                return
            if fd == master:
                # A closed or paused viewer must never stall the board or agent.
                excess = len(buffer) + len(data) - MAX_PENDING
                del buffer[:excess]
                print("Virtual terminal backlog full; old display data dropped", file=sys.stderr, flush=True)
            else:
                raise RuntimeError("Serial transmit backlog full")
        buffer.extend(data)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    with open(runtime / "bridge.lock", "a") as lock:
        os.chmod(runtime / "bridge.lock", 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with serial.Serial(port, baud, timeout=0, write_timeout=0,
                           rtscts=False, dsrdtr=False, exclusive=True) as physical:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                try:
                    for path in (user_port, agent_socket):
                        if path.is_symlink() or path.is_socket():
                            path.unlink()
                        elif path.exists():
                            raise RuntimeError("Refusing to overwrite " + str(path))

                    master, slave = pty.openpty()
                    tty.setraw(slave)
                    os.set_blocking(master, False)
                    # Keep the slave open so the master survives viewer disconnects.
                    os.symlink(os.ttyname(slave), user_port)
                    created_paths.append(user_port)
                    listener.bind(str(agent_socket))
                    created_paths.append(agent_socket)
                    os.chmod(agent_socket, 0o600)
                    listener.listen(8)
                    listener.setblocking(False)
                    serial_fd = physical.fileno()
                    os.set_blocking(serial_fd, False)
                    print(json.dumps({"pid": os.getpid(), "physical_port": port,
                                      "baud": baud, "user_port": str(user_port),
                                      "pty": os.ttyname(slave),
                                      "agent_socket": str(agent_socket)}), flush=True)

                    while running:
                        readers = [listener.fileno(), serial_fd, master, *clients]
                        writers = [fd for fd, data in pending.items() if data]
                        try:
                            readable, writable, _ = select.select(readers, writers, [], 0.5)
                        except InterruptedError:
                            continue

                        for fd in readable:
                            if fd == listener.fileno():
                                client, _ = listener.accept()
                                client.setblocking(False)
                                clients[client.fileno()] = client
                                continue
                            try:
                                data = os.read(fd, 65536)
                            except BlockingIOError:
                                continue
                            except OSError:
                                if fd in clients:
                                    disconnect(fd)
                                    continue
                                raise
                            if not data:
                                if fd in clients:
                                    disconnect(fd)
                                    continue
                                raise RuntimeError("Serial/PTY endpoint disconnected")
                            if fd == serial_fd:
                                enqueue(master, data)
                                for client_fd in list(clients):
                                    enqueue(client_fd, data)
                            else:
                                enqueue(serial_fd, data)

                        for fd in writable:
                            if fd not in pending or not pending[fd]:
                                continue
                            try:
                                count = os.write(fd, pending[fd])
                                del pending[fd][:count]
                            except BlockingIOError:
                                continue
                            except OSError as error:
                                if fd in clients:
                                    disconnect(fd)
                                elif error.errno != errno.EINTR:
                                    raise
                finally:
                    for client in clients.values():
                        client.close()
                    for path in created_paths:
                        path.unlink(missing_ok=True)
                    for fd in (master, slave):
                        if fd is not None:
                            os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", default="/dev/cu.usbserial-11410")
    parser.add_argument("--baud", type=int, default=1500000)
    parser.add_argument("--runtime", type=Path, default=Path("/private/tmp/rk3399-serial"))
    args = parser.parse_args()
    try:
        serve(args.port, args.baud, args.runtime.resolve())
    except (OSError, serial.SerialException, RuntimeError) as error:
        parser.exit(1, "serial bridge: " + str(error) + "\n")


if __name__ == "__main__":
    main()
