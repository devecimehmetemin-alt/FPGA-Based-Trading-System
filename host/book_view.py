"""Live view of the order book, read over AXI4-Lite from the PS.

Run it on the KR260 over SSH:

    sudo python3 host/book_view.py --base 0xA0000000

Each refresh writes the snapshot bit and then reads the shadow registers, so the
four BBO fields come from one instant. Reading them straight from the live book
would occasionally show a crossed market that never existed, because the fabric
updates between reads.

--replay renders the same display from a simulation dump instead, which needs no
board:

    python3 host/book_view.py --replay tb/vectors/bbo_expect.txt
"""

from __future__ import annotations

import argparse
import mmap
import os
import struct
import sys
import time

ID = 0x00
CTRL = 0x04
STATUS = 0x08
BBO_COUNT = 0x0C
BID_PRICE = 0x10
BID_QTY = 0x14
ASK_PRICE = 0x18
ASK_QTY = 0x1C
ORDERS = 0x20
LEVELS = 0x24
GAP_LO = 0x28
GAP_HI = 0x2C
COUNTERS = 0x30

MAGIC = 0x424F4F4B
CTRL_SNAP = 1
CTRL_RESYNC = 2

COUNTER_NAMES = [
    "seq gap", "duplicate", "frame drop", "bad fcs", "parse err",
    "rec fifo ovf", "lvl fifo ovf", "order ovf", "order miss", "order dup",
    "level ovf", "level miss",
]

CLEAR = "\x1b[2J\x1b[H"
HIDE = "\x1b[?25l"
SHOW = "\x1b[?25h"
DIM = "\x1b[2m"
RED = "\x1b[31m"
GREEN = "\x1b[32m"
BOLD = "\x1b[1m"
OFF = "\x1b[0m"


class Regs:
    """32-bit window onto the AXI-Lite slave via /dev/mem"""

    def __init__(self, base: int, size: int = 0x1000):
        page = mmap.PAGESIZE
        self.off = base % page
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.map = mmap.mmap(self.fd, size + self.off, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE,
                             offset=base - self.off)

    def read(self, reg: int) -> int:
        a = self.off + reg
        return struct.unpack("<I", self.map[a:a + 4])[0]

    def write(self, reg: int, val: int) -> None:
        a = self.off + reg
        self.map[a:a + 4] = struct.pack("<I", val & 0xFFFFFFFF)

    def close(self) -> None:
        self.map.close()
        os.close(self.fd)


def px(v: int) -> str:
    """ITCH prices carry four implied decimals"""
    return f"{v / 10000:.4f}"


def render(sym, bid_live, bid_p, bid_q, ask_live, ask_p, ask_q,
           orders, levels, updates, stale, degraded, counters, rate):
    out = [CLEAR]
    flag = f"{RED}STALE{OFF}" if stale else f"{GREEN}live{OFF}"
    deg = f" {RED}degraded{OFF}" if degraded else ""
    out.append(f"{BOLD}  AAPL{OFF}   book {flag}{deg}\n\n")

    bid = f"{px(bid_p):>12} x {bid_q:>7,}" if bid_live else f"{DIM}{'--':>12}{OFF}          "
    ask = f"{px(ask_p):>12} x {ask_q:>7,}" if ask_live else f"{DIM}{'--':>12}{OFF}          "
    out.append(f"          {'BID':>12}            |  {'ASK':<12}\n")
    out.append(f"  {GREEN}{bid}{OFF}   |  {RED}{ask}{OFF}\n")

    if bid_live and ask_live:
        spread = ask_p - bid_p
        mid = (ask_p + bid_p) / 2
        out.append(f"\n  spread {px(spread)}   mid {px(int(mid))}\n")
    else:
        out.append("\n  spread --\n")

    out.append(f"\n  resting orders {orders:>9,}\n")
    out.append(f"  price levels   {levels:>9,}\n")
    out.append(f"  bbo updates    {updates:>9,}   {rate:,.0f}/s\n")

    bad = [(n, c) for n, c in zip(COUNTER_NAMES, counters) if c]
    out.append("\n  faults: ")
    if not bad:
        out.append(f"{DIM}none{OFF}\n")
    else:
        out.append("\n")
        for n, c in bad:
            out.append(f"    {RED}{n:<14}{OFF} {c:,}\n")
    out.append(f"\n{DIM}  ctrl-c to exit{OFF}\n")
    sys.stdout.write("".join(out))
    sys.stdout.flush()


def run_live(base: int, hz: float) -> int:
    try:
        regs = Regs(base)
    except PermissionError:
        print("need root for /dev/mem, try sudo")
        return 1
    except FileNotFoundError:
        print("no /dev/mem, this mode only runs on the board")
        return 1

    ident = regs.read(ID)
    if ident != MAGIC:
        print(f"no book at 0x{base:08X}, read {ident:08X} expected {MAGIC:08X}")
        print("check the address assigned to the AXI slave in the block design")
        regs.close()
        return 1

    period = 1.0 / hz
    last_updates, last_t = 0, time.monotonic()
    sys.stdout.write(HIDE)
    try:
        while True:
            regs.write(CTRL, CTRL_SNAP)
            status = regs.read(STATUS)
            updates = regs.read(BBO_COUNT)
            now = time.monotonic()
            rate = (updates - last_updates) / max(now - last_t, 1e-6)
            last_updates, last_t = updates, now
            render(
                0,
                bool(status & 4), regs.read(BID_PRICE), regs.read(BID_QTY),
                bool(status & 8), regs.read(ASK_PRICE), regs.read(ASK_QTY),
                regs.read(ORDERS), regs.read(LEVELS), updates,
                bool(status & 1), bool(status & 2),
                [regs.read(COUNTERS + 4 * i) for i in range(len(COUNTER_NAMES))],
                rate,
            )
            time.sleep(period)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write(SHOW + "\n")
        regs.close()
    return 0


def run_replay(path: str, hz: float, speed: float) -> int:
    rows = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) == 7:
                rows.append([int(x) for x in p])
    if not rows:
        print(f"no bbo rows in {path}")
        return 1

    period = 1.0 / (hz * speed)
    sys.stdout.write(HIDE)
    try:
        for i, (sym, bl, bp, bq, al, ap, aq) in enumerate(rows):
            render(sym, bool(bl), bp, bq, bool(al), ap, aq,
                   0, 0, i + 1, False, False, [0] * len(COUNTER_NAMES), hz * speed)
            time.sleep(period)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write(SHOW + "\n")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0xA0000000,
                    help="AXI slave base address as assigned in the block design")
    ap.add_argument("--hz", type=float, default=10.0, help="refresh rate")
    ap.add_argument("--replay", metavar="BBO_FILE",
                    help="render a simulation dump instead of the board")
    ap.add_argument("--speed", type=float, default=1.0,
                    help="replay speed multiplier")
    args = ap.parse_args()

    if args.replay:
        return run_replay(args.replay, args.hz, args.speed)
    return run_live(args.base, args.hz)


if __name__ == "__main__":
    raise SystemExit(main())
