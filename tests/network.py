"""Deterministic lossy UDP proxy for testing Mosh recovery and roaming."""
import heapq
import os
import select
import socket
import threading
import time


class Network:
    def __init__(self, port_file):
        self.port_file = port_file
        self.front = self.socket()
        self.back = self.socket()
        self.port = self.front.getsockname()[1]
        self.running = True
        self.blackout_until = 0
        self.roam_requested = False
        self.dropped = self.duplicated = self.reordered = 0
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    @staticmethod
    def socket():
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        return sock

    def run(self):
        server = client = None
        queue = []
        count = 0
        while self.running:
            if server is None and os.path.exists(self.port_file):
                try:
                    with open(self.port_file) as f:
                        server = ("127.0.0.1", int(f.read()))
                except ValueError:
                    pass
            if self.roam_requested:
                self.back.close()
                self.back = self.socket()
                queue.clear()
                self.roam_requested = False
            for sock in select.select([self.front, self.back], [], [], 0.01)[0]:
                data, addr = sock.recvfrom(65536)
                count += 1
                if sock is self.front:
                    client = addr
                    dest, target = server, self.back
                else:
                    dest, target = client, self.front
                if not dest or time.monotonic() < self.blackout_until or count % 5 == 0:
                    self.dropped += 1
                    continue
                delay = 0.08 if count % 3 == 0 else 0.005
                if count % 3 == 0:
                    self.reordered += 1
                heapq.heappush(queue, (time.monotonic() + delay, count, target, dest, data))
                if count % 7 == 0:
                    self.duplicated += 1
                    heapq.heappush(queue, (time.monotonic() + delay + 0.02, count, target, dest, data))
            while queue and queue[0][0] <= time.monotonic():
                _, _, sock, dest, data = heapq.heappop(queue)
                if time.monotonic() >= self.blackout_until:
                    sock.sendto(data, dest)

    def close(self):
        self.running = False
        self.thread.join(timeout=2)
        self.front.close()
        self.back.close()
