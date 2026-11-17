"""Fake Canon SELPHY QX20 (CPNP) for testing drivers without hardware.

Emulates discovery/status/session over UDP and the print state machine over
TCP, and logs every request it receives (one JSON object per line) so the
traffic of two drivers can be compared.

    python fake_qx20.py --udp-port 18610 --tcp-port 18700 --log out.jsonl [--fail-paper]
"""
import argparse
import hashlib
import json
import socket
import struct
import threading

MAGIC = b"CPNP"


def reply(cmd, pid, body=b"", typ=0x81, session=0):
    return MAGIC + bytes([typ, cmd, 0, 0]) + struct.pack(">HHI", pid, session, len(body)) + body


class Log:
    def __init__(self, path):
        self.f = open(path, "w")
        self.lock = threading.Lock()

    def write(self, **kw):
        with self.lock:
            self.f.write(json.dumps(kw) + "\n")
            self.f.flush()


def udp_server(port, tcp_port, log):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    while True:
        data, addr = s.recvfrom(4096)
        cmd = data[5]
        pid = int.from_bytes(data[8:10], "big")
        log.write(ch="udp", cmd=cmd, pid=pid, hex=data.hex())
        if cmd == 0x30:  # discover
            out = reply(cmd, pid, b"\x00\x00MFG:Canon;CMD:Raster3;MDL:SELPHY QX20;CLS:PRINTER;")
        elif cmd == 0x20:  # status
            body = bytearray(512)
            body[2], body[3] = 1, 18
            struct.pack_into("<HHHH", body, 132, 644, 768, 848, 826)
            out = reply(cmd, pid, bytes(body))
        elif cmd == 0x10:  # session start
            r = bytearray(reply(cmd, pid, bytes(8)))
            r[6:8] = b"\x00\x00"           # result
            r[10:12] = (0x42).to_bytes(2, "big")  # session id
            r[20:22] = tcp_port.to_bytes(2, "big")
            out = bytes(r)
        else:  # session end and anything else
            out = reply(cmd, pid)
        s.sendto(out, addr)


def recv_exact(c, n):
    buf = b""
    while len(buf) < n:
        part = c.recv(n - len(buf))
        if not part:
            raise ConnectionError
        buf += part
    return buf


def tcp_client(c, log, fail_paper):
    state, jpeg_size, received, seq_i = "idle", 0, 0, 0
    seq = [0x01, 0x0C, 0x0D, 0x0D] if fail_paper else [0x01, 0x03, 0x05, 0x07, 0x09, 0x10, 0x0A]
    try:
        while True:
            hdr = recv_exact(c, 16)
            assert hdr[:4] == MAGIC
            cmd = hdr[5]
            pid, sess, size = struct.unpack(">HHI", hdr[8:16])
            body = recv_exact(c, size) if size else b""
            entry = dict(ch="tcp", cmd=cmd, pid=pid, session=sess, size=size)
            if size <= 200:
                entry["body"] = body.hex()
            else:
                entry["body_sha"] = hashlib.sha1(body).hexdigest()[:12]
                entry["head"] = body[:104].hex()
            log.write(**entry)

            if cmd == 0x52:
                c.sendall(reply(cmd, pid, session=sess))
            elif cmd == 0x51:
                c.sendall(reply(cmd, pid, (33792).to_bytes(4, "big"), session=sess))
            elif cmd == 0x21:  # write
                code = int.from_bytes(body[2:4], "little") if len(body) >= 4 else -1
                if state == "idle" and len(body) == 64 and code == 0:
                    state = "want_probe"
                elif state == "want_probe" and len(body) == 105:
                    jpeg_size = int.from_bytes(body[20:24], "little")
                    state = "want_jpeg"
                elif state == "want_jpeg":
                    received += len(body)
                    if received >= 104 + jpeg_size:
                        state = "printing"
                c.sendall(reply(cmd, pid, len(body).to_bytes(4, "big"), session=sess))
            elif cmd == 0x20:  # read
                p = bytearray(64)
                p[9] = 0xFF
                if state == "want_probe":
                    p[8] = 1
                    struct.pack_into("<II", p, 24, 16, 1)
                elif state == "want_jpeg":
                    p[8] = 1
                    struct.pack_into("<II", p, 24, 0, jpeg_size)
                elif state == "printing":
                    p[8] = seq[min(seq_i, len(seq) - 1)]
                    seq_i += 1
                c.sendall(reply(cmd, pid, bytes(p), session=sess))
            else:
                c.sendall(reply(cmd, pid, session=sess))
    except (ConnectionError, OSError):
        pass
    finally:
        c.close()


def tcp_server(port, log, fail_paper):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen()
    while True:
        c, _ = s.accept()
        threading.Thread(target=tcp_client, args=(c, log, fail_paper), daemon=True).start()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--udp-port", type=int, default=18610)
    ap.add_argument("--tcp-port", type=int, default=18700)
    ap.add_argument("--log", required=True)
    ap.add_argument("--fail-paper", action="store_true")
    a = ap.parse_args()
    log = Log(a.log)
    threading.Thread(target=udp_server, args=(a.udp_port, a.tcp_port, log), daemon=True).start()
    print(f"fake QX20 on udp {a.udp_port}, tcp {a.tcp_port}", flush=True)
    tcp_server(a.tcp_port, log, a.fail_paper)
