#!/usr/bin/env python3
"""Local-only SSH stand-in; still starts the actual stock mosh-server."""
import os
import re
import subprocess
import sys

os.environ["SSH_CONNECTION"] = "127.0.0.1 12345 127.0.0.1 22"
if "MOSH_TEST_PORT_FILE" not in os.environ:
    os.execv("/bin/sh", ["sh", "-c", sys.argv[-1]])
result = subprocess.run(["sh", "-c", sys.argv[-1]], stdout=subprocess.PIPE)
output = result.stdout
match = re.search(rb"MOSH CONNECT (\d+) ", output)
if match:
    with open(os.environ["MOSH_TEST_PORT_FILE"], "w") as f:
        f.write(match[1].decode())
    output = output[:match.start(1)] + os.environ["MOSH_TEST_PROXY_PORT"].encode() + output[match.end(1):]
sys.stdout.buffer.write(output)
sys.exit(result.returncode)
