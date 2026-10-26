# zig-mosh

A Linux Mosh client implemented in Zig. SSH launches the remote `mosh-server`;
the Zig executable then handles the encrypted UDP session itself.

## Connect

```sh
./build.sh
./mosh user@server.example
```

The build creates `zig-out/bin/mosh`. To use the command as `mosh` in this shell:

```sh
export PATH="$PWD/zig-out/bin:$PATH"
mosh user@server.example
```

SSH configuration, identities, host aliases, and authentication work through
your installed `ssh`. The client uses the server address reported by that SSH
connection. When connecting over Tailscale, use the remote machine's MagicDNS
name or Tailscale IP. Tailscale must be connected at both ends; the host needs `mosh-server`
and reachable UDP ports (normally 60000–61000).

```sh
./mosh -p 60001 user@server.example
./mosh --ssh-port 2222 -i ~/.ssh/id_ed25519 user@host
./mosh user@server.example -- tmux new-session -A -s main
./mosh --help
```

Exit with `exit` in the remote shell, or **Ctrl-^ followed by `.`**
(usually Ctrl-Shift-6, then period). Press Ctrl-^ twice to send it literally.

## Build and test

Requires **Zig 0.15.2**, libc development headers, OpenSSL with AES-OCB support,
and zlib development headers/libraries. Python 3 and a stock `mosh-server` are
needed for the integration tests.

```sh
./build.sh
./build.sh test
# Or: zig build -Doptimize=ReleaseSafe && zig build test
python3 tests/smoke.py --local
python3 tests/smoke.py --faults
python3 tests/smoke.py user@server.example
```

`ZIG=/path/to/zig ./build.sh` selects a particular toolchain. The `./mosh`
launcher builds if the binary is absent; run `./build.sh` after editing sources.
`build.sh` uses a local `.tools/zig` toolchain when available; toolchains and
build outputs are excluded from the repository.
The fault test injects packet loss, duplication, reordering, a six-second outage,
and a changed UDP source port against the stock local server.

## Implementation

- Mosh protocol 2 protobuf encoding/decoding, zlib compression, fragmentation.
- AES-128-OCB authenticated encryption using OpenSSL; independent packet nonces.
- Acknowledged input batches, retransmissions, keepalives, shutdown handshake.
- Retained terminal snapshots for updates based on older states, including
  reordered/lost updates; no blind replay of terminal diffs.
- UTF-8 cells, wide/combining characters, ANSI colors/attributes, scrolling,
  cursor state, bracketed paste, mouse modes, and terminal resizing.
- Raw terminal mode with restoration on normal exit, SIGINT, SIGTERM, SIGHUP.
- IPv4/IPv6 UDP; retrying through network outages while keeping the session.

This is an initial implementation, not complete upstream feature parity.
It has no speculative local echo, suspend/resume UI, or dynamic UDP port hopping.
Terminal title, clipboard, and hyperlink OSC sequences are currently ignored.
The renderer covers the terminal-update language emitted by stock Mosh servers,
rather than being a general-purpose terminal emulator. Input uses conservative
stop-and-wait batching, so high-latency links may feel slower than upstream Mosh.

## Source map

`src/bootstrap.zig`: SSH startup and handshake.
`src/wire.zig`: protobuf, encryption, compression, fragmentation.
`src/transport.zig`: UDP and synchronized state management.
`src/terminal.zig`: terminal snapshots and rendering.
`src/main.zig`: CLI, terminal lifecycle, input loop.

Protocol interoperability was developed using the public Mosh protocol schemas
and upstream source at <https://github.com/mobile-shell/mosh> as reference.
