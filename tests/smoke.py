#!/usr/bin/env python3
"""End-to-end test against an installed, SSH-accessible mosh-server."""
import argparse
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import termios
import time
import tempfile
from network import Network


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host", nargs="?", help="SSH destination (required unless --local or --faults)")
    parser.add_argument("--binary", default="./zig-out/bin/mosh")
    parser.add_argument("--local", action="store_true", help="Use local mosh-server via a test SSH shim")
    parser.add_argument("--faults", action="store_true", help="Local packet loss, duplicates, reordering, outage, roaming")
    args = parser.parse_args()
    if args.host is None:
        if not (args.local or args.faults):
            parser.error("specify an SSH destination, or use --local / --faults")
        args.host = "localhost"
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    before = termios.tcgetattr(slave)
    env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8")
    shim = tempfile.TemporaryDirectory(prefix="zig-mosh-test-")
    proxy = None
    if args.local or args.faults:
        path = os.path.join(shim.name, "ssh")
        os.symlink(os.path.abspath(os.path.join(os.path.dirname(__file__), "ssh_shim.py")), path)
        env["PATH"] = shim.name + os.pathsep + env["PATH"]
    if args.faults:
        port_file = os.path.join(shim.name, "port")
        proxy = Network(port_file)
        env["MOSH_TEST_PORT_FILE"] = port_file
        env["MOSH_TEST_PROXY_PORT"] = str(proxy.port)
    # A clean interactive shell avoids user startup files and prompt plugins.
    proc = subprocess.Popen([args.binary, args.host, "--", "sh", "-c",
        "printf 'ZIG_MOSH_READY\\n'; exec env PS1='zig-test> ' sh -i"],
        stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
    captured = bytearray()

    def wait_for(marker, timeout=25):
        deadline = time.monotonic() + timeout
        start = len(captured)
        while time.monotonic() < deadline:
            if marker in captured[start:]:
                return
            if select.select([master], [], [], 0.2)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                captured.extend(chunk)
            if proc.poll() is not None:
                break
        raise AssertionError(f"Missing {marker!r}; exit={proc.poll()}; output={bytes(captured)!r}")

    try:
        wait_for(b"ZIG_MOSH_READY")
        os.write(master, b"printf '\\132\\111\\107_OK_%s\\n' \"$(hostname)\"\r")
        wait_for(b"ZIG_OK_")
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
        time.sleep(0.8)
        os.write(master, b"stty size\r")
        wait_for(b"32 100")
        os.write(master, b"printf '\\033[31m\\103\\117\\114\\117\\122_OK\\033[0m\\n'\r")
        wait_for(b"COLOR_OK")
        os.write(master, b'''awk 'BEGIN {for(y=0;y<25;y++){for(x=0;x<85;x++)printf "%c",33+int(rand()*90);print ""} print "FRAGMENT_" "OK"}'\r''')
        wait_for(b"FRAGMENT_OK")
        if proxy:
            proxy.blackout_until = time.monotonic() + 6
            os.write(master, b"printf '\\122\\105\\103\\117\\126\\105\\122_OK\\n'\r")
            wait_for(b"RECOVER_OK", timeout=30)
            proxy.roam_requested = True
            os.write(master, b"printf '\\122\\117\\101\\115_OK\\n'\r")
            wait_for(b"ROAM_OK", timeout=30)
            assert proxy.dropped and proxy.duplicated and proxy.reordered
        os.write(master, b"exit\r")
        proc.wait(timeout=10)
        assert proc.returncode == 0, proc.returncode
        assert termios.tcgetattr(slave) == before, "terminal settings not restored"
        target = "local stock mosh-server" if args.local or args.faults else args.host
        print(f"PASS: {target}: encrypted UDP, keyboard, hostname, resize, color, fragmentation, exit, terminal restoration")
        if proxy:
            print(f"PASS: recovery after 6s outage and UDP source-port roaming; dropped={proxy.dropped}, duplicated={proxy.duplicated}, delayed={proxy.reordered}")
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        os.close(master)
        os.close(slave)
        if proxy:
            proxy.close()
        shim.cleanup()


if __name__ == "__main__":
    main()
