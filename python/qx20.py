"""
loveletter-qx20 — Open-source Canon SELPHY QX20 printer driver.

First ever open-source implementation of Canon's CPNP (Canon Proprietary
Network Protocol) for the SELPHY QX20 photo printer.

By Uzu, Solinelle & Codex — 2026-05-05 (Children's Day 🎏)

Usage:
    from qx20 import QX20Printer
    printer = QX20Printer()
    printer.discover()
    printer.print_image("photo.jpg")
"""

import io
import socket
import struct
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from PIL import Image

CPNP_MAGIC = b"CPNP"
CPNP_PORT = 8609
PRINTER_IP = "192.168.0.1"
MAX_WRITE_SIZE = 33792
OVERCOAT_GLOSSY = 2

# QX20 prints at 287 dpi (Canon spec). The image canvas is slightly larger
# than the sheet so prints can be borderless; the excess bleeds off the edge.
QX20_DPI = 287

# Paper profiles. size_code is the StartPrint media code.
#   bleed_mm: how much of the canvas is lost on each side (left, top, right,
#   bottom) when printed borderless. Used by fit mode so nothing gets cut.
PAPERS = {
    # XC-20L / XC-60L, 54x85 mm sheet
    # Bleed measured with calibrate.py: 2 mm lost left/right, 1 mm top/bottom.
    "card": dict(width=644, height=826, size_code=18,
                 bleed_mm=(2.0, 1.0, 2.0, 1.0)),
    # XS-20L, 72x85 mm sheet. Media code 17 verified on hardware (2026-11-19).
    # Bleed assumed equal to card (848 px @287dpi = 75 mm on a 72 mm sheet,
    # same ~1.5 mm/side overhang); re-run calibrate.py square to confirm.
    "square": dict(width=848, height=826, size_code=17,
                   bleed_mm=(2.0, 1.0, 2.0, 1.0)),
}
DEFAULT_PAPER = "card"

# Backwards-compatible aliases
QX20_PRINT_SIZE = PAPERS["card"]["size_code"]
QX20_WIDTH = PAPERS["card"]["width"]
QX20_HEIGHT = PAPERS["card"]["height"]


def mm_to_px(mm: float) -> int:
    return max(0, round(mm / 25.4 * QX20_DPI))


def prepare_image(image_path: str, mode: str = "fit",
                  border_mm: float = 0.0, paper: str = DEFAULT_PAPER,
                  safe: bool = True) -> Image.Image:
    """Load an image and fit it to the QX20 canvas without distortion.

    - Applies EXIF orientation (phone photos).
    - Rotates landscape images to portrait so they use the whole sheet.
    - mode "fill": scale to cover the canvas and center-crop the excess.
    - mode "fit": scale to fit inside the canvas, pad with white.
    - mode "stretch": resize ignoring aspect ratio.
    - border_mm: white margin added on every side.
    - paper: "card" or "square".
    - safe: in fit mode, keep the image inside the paper's bleed margins so
      nothing is cut off by borderless printing.
    """
    from PIL import ImageOps

    if mode not in ("fill", "fit", "stretch"):
        raise ValueError(f"unknown mode: {mode}")

    img = Image.open(image_path)
    img = ImageOps.exif_transpose(img)
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
        img = Image.alpha_composite(bg, img)
    img = img.convert("RGB")

    if paper not in PAPERS:
        raise ValueError(f"unknown paper: {paper}")
    prof = PAPERS[paper]
    cw, ch = prof["width"], prof["height"]

    # Match orientation to the canvas (only matters for the tall card format)
    if (img.width > img.height) != (cw > ch) and abs(cw - ch) > 50:
        img = img.rotate(90, expand=True)

    bl, bt, br, bb = (mm_to_px(m) for m in prof["bleed_mm"]) if (safe and mode == "fit") else (0, 0, 0, 0)
    border = mm_to_px(border_mm)
    left, top = bl + border, bt + border
    inner_w = cw - left - br - border
    inner_h = ch - top - bb - border
    if inner_w <= 0 or inner_h <= 0:
        raise ValueError("border too large")

    if mode == "stretch":
        content = img.resize((inner_w, inner_h), Image.LANCZOS)
    elif mode == "fill":
        content = ImageOps.fit(img, (inner_w, inner_h), Image.LANCZOS)
    else:  # fit
        content = ImageOps.contain(img, (inner_w, inner_h), Image.LANCZOS)

    canvas = Image.new("RGB", (cw, ch), (255, 255, 255))
    canvas.paste(content, (left + (inner_w - content.width) // 2,
                           top + (inner_h - content.height) // 2))
    return canvas


# Normal print states seen on hardware: 0x01 ready -> 0x03/0x05/0x07 (Y/M/C
# passes) -> 0x09 (overcoat) -> 0x10 -> 0x0A done. With an empty paper
# cassette the printer goes 0x0C -> 0x0D and lights the red error LED.
PRINT_ERROR_STATES = (0x0C, 0x0D)


class PrinterError(Exception):
    """The printer reported a hardware error (no paper, jam, ...)."""


@dataclass
class PrinterStatus:
    paper: int = 0
    ink: int = 0
    error: int = 0
    min_w: int = 0
    min_h: int = 0
    max_w: int = 0
    max_h: int = 0
    device_id: str = ""


class QX20Printer:
    """Canon SELPHY QX20 printer driver via CPNP protocol."""

    def __init__(self, ip: str = PRINTER_IP):
        self.ip = ip
        self._packet_id = 0
        self._session_id = 0
        self._tcp_port = 0
        self._udp: Optional[socket.socket] = None
        self._tcp: Optional[socket.socket] = None

    def _next_id(self) -> int:
        self._packet_id += 1
        if self._packet_id > 65535:
            self._packet_id = 1
        return self._packet_id

    @staticmethod
    def _p16be(b, o, v):
        b[o] = (v >> 8) & 0xFF
        b[o + 1] = v & 0xFF

    @staticmethod
    def _p32be(b, o, v):
        b[o] = (v >> 24) & 0xFF
        b[o + 1] = (v >> 16) & 0xFF
        b[o + 2] = (v >> 8) & 0xFF
        b[o + 3] = v & 0xFF

    @staticmethod
    def _p16le(b, o, v):
        b[o] = v & 0xFF
        b[o + 1] = (v >> 8) & 0xFF

    @staticmethod
    def _p32le(b, o, v):
        b[o] = v & 0xFF
        b[o + 1] = (v >> 8) & 0xFF
        b[o + 2] = (v >> 16) & 0xFF
        b[o + 3] = (v >> 24) & 0xFF

    # ── Low-level transport ──────────────────────────────────

    @staticmethod
    def _recv_exact(sock: socket.socket, n: int) -> bytes:
        out = bytearray()
        while len(out) < n:
            part = sock.recv(n - len(out))
            if not part:
                raise ConnectionError("socket closed")
            out.extend(part)
        return bytes(out)

    def _recv_cpnp(self, sock: socket.socket, expected_cmd=None, expected_pid=None):
        hdr = self._recv_exact(sock, 16)
        if hdr[:4] != CPNP_MAGIC:
            raise ValueError(f"bad CPNP magic: {hdr.hex()}")
        typ, cmd = hdr[4], hdr[5]
        pkt_id = int.from_bytes(hdr[8:10], "big")
        size = int.from_bytes(hdr[12:16], "big")
        body = self._recv_exact(sock, size) if size else b""
        if expected_cmd is not None and cmd != expected_cmd:
            raise ValueError(f"unexpected cmd: {cmd:#04x}, want {expected_cmd:#04x}")
        if expected_pid is not None and pkt_id != expected_pid:
            raise ValueError(f"unexpected pid: {pkt_id}, want {expected_pid}")
        return typ, cmd, pkt_id, body

    def _tcp_write(self, data: bytes) -> int:
        """Send CPNP Write, return accepted byte count."""
        hdr = bytearray(16)
        hdr[:4] = CPNP_MAGIC
        hdr[4] = 0x01
        hdr[5] = 0x21
        pid = self._next_id()
        self._p16be(hdr, 8, pid)
        self._p16be(hdr, 10, self._session_id)
        self._p32be(hdr, 12, len(data))
        self._tcp.sendall(bytes(hdr) + data)
        typ, cmd, _, body = self._recv_cpnp(self._tcp, expected_cmd=0x21, expected_pid=pid)
        if typ != 0x81 or len(body) < 4:
            raise ValueError(f"bad write ack: typ={typ:#04x} body={body.hex()}")
        return int.from_bytes(body[:4], "big")

    def _tcp_read(self) -> bytes:
        """Send CPNP Read and return payload (CPNPConnected, 64 bytes)."""
        pkt = bytearray(16)
        pkt[:4] = CPNP_MAGIC
        pkt[4] = 0x01
        pkt[5] = 0x20
        pid = self._next_id()
        self._p16be(pkt, 8, pid)
        self._p16be(pkt, 10, self._session_id)
        self._tcp.sendall(bytes(pkt))
        time.sleep(0.05)
        typ, cmd, _, body = self._recv_cpnp(self._tcp, expected_cmd=0x20, expected_pid=pid)
        if typ != 0x81:
            raise ValueError(f"bad read ack: typ={typ:#04x}")
        return body

    def _send_command(self, data: bytes) -> None:
        """Send command data using sock.write loop (chunks of MAX_WRITE_SIZE)."""
        offset = 0
        while offset < len(data):
            chunk = min(MAX_WRITE_SIZE, len(data) - offset)
            accepted = self._tcp_write(data[offset:offset + chunk])
            if accepted <= 0 or accepted > chunk:
                raise ValueError(f"bad accepted: {accepted}, chunk={chunk}")
            offset += accepted

    # ── Protocol commands ────────────────────────────────────

    def _udp_send_recv(self, pkt: bytes) -> bytes:
        self._udp.sendto(pkt, (self.ip, CPNP_PORT))
        time.sleep(0.2)
        data, _ = self._udp.recvfrom(4096)
        return data

    def _session_end(self) -> None:
        pkt = bytearray(16)
        pkt[:4] = CPNP_MAGIC
        pkt[4] = 0x01
        pkt[5] = 0x11
        self._p16be(pkt, 8, self._next_id())
        try:
            self._udp_send_recv(bytes(pkt))
        except socket.timeout:
            pass

    def _session_start(self) -> None:
        buf = bytearray(408)
        buf[:4] = CPNP_MAGIC
        buf[4] = 0x01
        buf[5] = 0x10
        self._p16be(buf, 8, self._next_id())
        buf[14] = 0x01
        buf[15] = 0x88
        name = "loveletter".encode("utf-16-be")
        buf[24:24 + len(name)] = name
        su = bytes([0, 83, 0, 80, 0, 76, 0, 32, 0, 118, 0, 50, 0, 46, 0, 48])
        buf[88:88 + len(su)] = su
        sd = bytes([0, 83, 0, 113, 0, 117, 0, 97, 0, 114, 0, 101])
        buf[152:152 + len(sd)] = sd
        data = self._udp_send_recv(bytes(buf))
        result = data[6] * 256 + data[7]
        self._session_id = data[10] * 256 + data[11]
        self._tcp_port = data[21] + data[20] * 256
        if result != 0 or self._session_id == 0 or self._tcp_port == 0:
            raise ConnectionError(f"session start failed: result={result} sid={self._session_id} port={self._tcp_port}")

    def _negotiate_max_write_size(self) -> None:
        spkt = bytearray(20)
        spkt[:4] = CPNP_MAGIC
        spkt[4] = 0x01
        spkt[5] = 0x52
        self._p16be(spkt, 8, self._next_id())
        self._p16be(spkt, 10, self._session_id)
        self._p32be(spkt, 12, 4)
        self._p32be(spkt, 16, MAX_WRITE_SIZE)
        self._tcp.sendall(bytes(spkt))
        self._recv_cpnp(self._tcp)
        gpkt = bytearray(16)
        gpkt[:4] = CPNP_MAGIC
        gpkt[4] = 0x01
        gpkt[5] = 0x51
        self._p16be(gpkt, 8, self._next_id())
        self._p16be(gpkt, 10, self._session_id)
        self._tcp.sendall(bytes(gpkt))
        self._recv_cpnp(self._tcp)

    def _make_print_header(self, jpeg_size: int, width: int, height: int,
                           offset: int, chunk_size: int) -> bytes:
        h = bytearray(104)
        self._p16le(h, 0, 0)              # typePrint
        self._p16le(h, 2, 1)              # codePrintDataTransfer
        self._p32le(h, 4, 104 + chunk_size)
        self._p32le(h, 8, 0)              # typeJpegEasyPrint
        self._p32le(h, 12, 1)             # totalJpegImages
        self._p32le(h, 16, 0)             # jpegImageNo
        self._p32le(h, 20, jpeg_size)
        self._p32le(h, 24, width)
        self._p32le(h, 28, height)
        self._p32le(h, 96, offset)
        self._p32le(h, 100, chunk_size)
        return bytes(h)

    def _wait_for_request(self, want_offset: int, want_size: int,
                          label: str = "", max_polls: int = 120) -> bytes:
        for i in range(max_polls):
            payload = self._tcp_read()
            if len(payload) >= 32:
                req_offset = int.from_bytes(payload[24:28], "little")
                req_size = int.from_bytes(payload[28:32], "little")
                if payload[8] == 0x01 and payload[9] == 0xFF and \
                   req_offset == want_offset and req_size == want_size:
                    return payload
            time.sleep(0.05)
        raise TimeoutError(f"timed out waiting for {label}")

    # ── Public API ───────────────────────────────────────────

    def discover(self) -> str:
        """Discover the printer and return its device ID string."""
        self._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._udp.settimeout(3)
        self._udp.bind(("", CPNP_PORT))
        try:
            pkt = bytearray(20)
            pkt[:4] = CPNP_MAGIC
            pkt[4] = 0x01
            pkt[5] = 0x30
            self._p16be(pkt, 8, self._next_id())
            pkt[14] = 0x00
            pkt[15] = 0x04
            data = self._udp_send_recv(bytes(pkt))
            payload = data[16:]
            chars = [chr(b) for b in payload if 32 <= b < 127]
            return "".join(chars).strip()
        finally:
            self._udp.close()
            self._udp = None

    def status(self) -> PrinterStatus:
        """Read printer status (paper, ink, error, image size range)."""
        self._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._udp.settimeout(3)
        self._udp.bind(("", CPNP_PORT))
        try:
            pkt = bytearray(16)
            pkt[:4] = CPNP_MAGIC
            pkt[4] = 0x01
            pkt[5] = 0x20
            self._p16be(pkt, 8, self._next_id())
            data = self._udp_send_recv(bytes(pkt))
            if len(data) < 528:
                raise ValueError("short status response")
            p = data[16:]
            return PrinterStatus(
                paper=p[2], ink=p[3],
                error=int.from_bytes(p[68:72], "little"),
                min_w=int.from_bytes(p[132:134], "little"),
                min_h=int.from_bytes(p[134:136], "little"),
                max_w=int.from_bytes(p[136:138], "little"),
                max_h=int.from_bytes(p[138:140], "little"),
            )
        finally:
            self._udp.close()
            self._udp = None

    def print_image(self, image_path: str, on_progress=None,
                    mode: str = "fit", border_mm: float = 0.0,
                    paper: str = DEFAULT_PAPER, size_code: Optional[int] = None,
                    safe: bool = True) -> bool:
        """Print an image to the QX20. Returns True on success.

        Args:
            image_path: Path to image file (any format PIL supports).
            on_progress: Optional callback(stage: str, detail: str).
            mode: "fill" (crop to cover), "fit" (no crop, white bars)
                  or "stretch" (original behaviour).
            border_mm: Extra white border around the image, in mm.
            paper: "card" (XC-20L) or "square" (XS-20L).
            size_code: override the StartPrint media code.
            safe: keep fit-mode images inside the bleed margins.
        """
        def progress(stage, detail=""):
            if on_progress:
                on_progress(stage, detail)

        # Prepare JPEG
        prof = PAPERS[paper]
        if size_code is None:
            size_code = prof["size_code"]
        if size_code is None:
            raise ValueError(f"media code for paper '{paper}' is unknown; pass size_code")
        width, height = prof["width"], prof["height"]
        progress("preparing", f"encoding JPEG (paper={paper} {width}x{height}, "
                              f"code={size_code}, mode={mode}, border={border_mm}mm)")
        img = prepare_image(image_path, mode=mode, border_mm=border_mm,
                            paper=paper, safe=safe)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=95,
                 subsampling="4:4:4", restart_marker_blocks=81)
        jpeg = buf.getvalue()

        # UDP session
        progress("connecting", "UDP session")
        self._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._udp.settimeout(3)
        self._udp.bind(("", CPNP_PORT))
        try:
            self._session_end()
            time.sleep(1)
            self._session_start()
        finally:
            self._udp.close()
            self._udp = None

        # TCP connection
        progress("connecting", f"TCP port {self._tcp_port}")
        self._tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._tcp.settimeout(30)
        self._tcp.connect((self.ip, self._tcp_port))
        self._tcp.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        try:
            self._negotiate_max_write_size()

            # StartPrint
            progress("printing", "StartPrint")
            sp = bytearray(64)
            self._p16le(sp, 0, 0)
            self._p16le(sp, 2, 0)
            self._p32le(sp, 4, 64)
            self._p32le(sp, 8, 0)
            self._p16le(sp, 12, 1)
            self._p16le(sp, 14, size_code)
            sp[16] = OVERCOAT_GLOSSY
            self._tcp_write(bytes(sp))

            # Wait for probe request
            progress("printing", "waiting for probe request")
            self._wait_for_request(16, 1, "probe request")

            # Send probe
            probe_h = bytearray(self._make_print_header(len(jpeg), width, height, 16, 1))
            self._p32le(probe_h, 4, 105)
            self._tcp_write(bytes(probe_h) + b"\x00")

            # Wait for JPEG request
            progress("printing", "waiting for JPEG request")
            self._wait_for_request(0, len(jpeg), "jpeg request")

            # Send JPEG data
            progress("printing", f"sending {len(jpeg)} bytes")
            hdr = self._make_print_header(len(jpeg), width, height, 0, len(jpeg))
            self._send_command(hdr + jpeg)

            # Poll for completion
            progress("printing", "processing")
            last_status = None
            last_payload = None
            for i in range(300):
                payload = self._tcp_read()
                if len(payload) >= 42:
                    b8 = payload[8]
                    printed = payload[41]
                    if printed > 0:
                        progress("done", f"printed={printed}")
                        break
                    if b8 == 0x0A:
                        progress("printing", "finalizing")
                        break
                    if b8 in PRINT_ERROR_STATES:
                        progress("debug", f"raw={payload[:64].hex()}")
                        raise PrinterError(
                            f"la impresora reportó error (estado {b8:#04x}): "
                            "revisa que haya papel y que no esté atorado, "
                            "luego apágala y préndela")
                    if last_status is not None and b8 != last_status:
                        progress("printing", f"status {last_status:#04x} -> {b8:#04x}")
                    if payload != last_payload:
                        progress("debug", f"t={i * 0.5:.1f}s raw={payload[:64].hex()}")
                        last_payload = payload
                    last_status = b8
                time.sleep(0.5)

            # EndPrint
            ep = bytearray(64)
            self._p16le(ep, 0, 0)
            self._p16le(ep, 2, 3)
            self._p32le(ep, 4, 64)
            self._tcp_write(bytes(ep))
            progress("done", "EndPrint sent")

            # Brief wait
            time.sleep(5)
            return True

        finally:
            self._tcp.close()
            self._tcp = None

    def cancel(self) -> None:
        """Cancel the current print job."""
        if self._tcp:
            cp = bytearray(64)
            self._p16le(cp, 0, 0)
            self._p16le(cp, 2, 2)  # codeExecuteCancelPrint
            self._p32le(cp, 4, 64)
            try:
                self._tcp_write(bytes(cp))
            except Exception:
                pass


# ── CLI ──────────────────────────────────────────────────────

def main():
    import argparse
    import sys
    ap = argparse.ArgumentParser(description="Print to a Canon SELPHY QX20")
    ap.add_argument("images", nargs="*", help="image(s) to print (omit to show status)")
    ap.add_argument("--mode", "-m", choices=["fill", "fit", "stretch"], default="fit",
                    help="fit = whole image with white bars (default), fill = crop to cover")
    ap.add_argument("--border", "-b", type=float, default=0.0, help="white border in mm")
    ap.add_argument("--paper", choices=list(PAPERS), default=DEFAULT_PAPER,
                    help="card = XC-20L 54x85mm (default), square = XS-20L 72x85mm")
    ap.add_argument("--size-code", type=int, default=None,
                    help="override the printer media code (advanced)")
    ap.add_argument("--no-safe", action="store_true",
                    help="fit mode: ignore bleed margins (image may be cut at the edges)")
    ap.add_argument("--preview", "-p", metavar="OUT",
                    help="save the prepared image to OUT and exit without printing")
    args = ap.parse_args()
    paths = args.images
    path = paths[0] if paths else None
    printer = QX20Printer()

    if path and args.preview:
        prepare_image(path, mode=args.mode, border_mm=args.border,
                      paper=args.paper, safe=not args.no_safe).save(args.preview)
        print(f"Preview saved to {args.preview}")
        sys.exit(0)

    if path is None:
        print("Usage: python qx20.py <image_path> [--paper card|square] [--mode fit|fill|stretch] [--border MM] [--preview OUT]")
        print("\nDiscovering printer...")
        try:
            dev_id = printer.discover()
            print(f"  Device: {dev_id}")
        except Exception as e:
            print(f"  Error: {e}")
        print("\nReading status...")
        try:
            st = printer.status()
            print(f"  Paper: {st.paper}, Ink: {st.ink}, Error: {st.error}")
            print(f"  Image range: {st.min_w}x{st.min_h} ~ {st.max_w}x{st.max_h}")
        except Exception as e:
            print(f"  Error: {e}")
        sys.exit(0)

    sent = {"data": False}

    def on_progress(stage, detail):
        print(f"  [{stage}] {detail}", flush=True)
        if detail.startswith("sending "):
            sent["data"] = True

    failed = 0
    for i, path in enumerate(paths, 1):
        for attempt in range(1, 4):
            print(f"Printing ({i}/{len(paths)}): {path}"
                  + (f"  [reintento {attempt}]" if attempt > 1 else ""), flush=True)
            sent["data"] = False
            try:
                printer.print_image(path, on_progress=on_progress,
                                    mode=args.mode, border_mm=args.border,
                                    paper=args.paper, size_code=args.size_code,
                                    safe=not args.no_safe)
                print("Success!", flush=True)
                break
            except PrinterError as e:
                failed += 1
                print(f"Error: {e}", flush=True)
                if i < len(paths):
                    print(f"Se cancelan las {len(paths) - i} imágenes restantes.", flush=True)
                sys.exit(1)
            except (OSError, TimeoutError) as e:
                printer._tcp = None
                if sent["data"]:
                    # The printer already has the whole image; it normally
                    # finishes on its own. Don't reprint to avoid a duplicate.
                    print(f"Conexión perdida después de enviar la imagen ({e}). "
                          "La impresora ya tenía los datos; probablemente sí se imprimió.", flush=True)
                    time.sleep(60)  # let the printer finish before the next job
                    break
                if attempt == 3:
                    failed += 1
                    print(f"Error: {e}", flush=True)
                    break
                print(f"  Error de conexión ({e}); reintentando en 8s...", flush=True)
                time.sleep(8)
            except Exception as e:
                failed += 1
                print(f"Error: {e}", flush=True)
                import traceback
                traceback.print_exc()
                break
        if i < len(paths):
            time.sleep(3)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
