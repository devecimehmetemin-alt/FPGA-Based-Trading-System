#!/usr/bin/env python3
"""Extract a full session of one symbol's order records straight from the capture.

tb_book_top drives the whole chain from Ethernet beats, which is the right test for
correctness but caps the book at a few dozen live orders: reaching the real depth
that way means simulating tens of millions of unrelated messages through the filter.
This writes the record stream that survives symbol_filter, so a testbench can drive
the book at full session depth in a few hundred thousand cycles.

Records are packed exactly as book_top's record fifo carries them, 203 bits:

    {type[8] ref[64] ref2[64] shares[32] price[32] side[1] sym[2]}

Reads  the raw NASDAQ ITCH 5.0 file, 2 byte big endian length then the message
Writes tb/vectors/book_records.hex   one packed record per line
       tb/vectors/book_records.txt   count peak_live final_live
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "golden"))

from order_store_model import Store

CHUNK = 1 << 24

T_ADD = 0x41
T_ADD_ATTR = 0x46
T_EXEC = 0x45
T_EXEC_PRICE = 0x43
T_CANCEL = 0x58
T_DELETE = 0x44
T_REPLACE = 0x55
T_DIRECTORY = 0x52

KEEP = {T_ADD, T_ADD_ATTR, T_EXEC, T_EXEC_PRICE, T_CANCEL, T_DELETE, T_REPLACE}
ADDS = {T_ADD, T_ADD_ATTR}
REDUCERS = {T_EXEC, T_EXEC_PRICE, T_CANCEL}


def find_locate(path: Path, want: bytes, scan: int) -> int:
    """the stock directory at the head of the session maps the symbol to its locate"""
    with path.open("rb") as f:
        seen = 0
        while seen < scan:
            prefix = f.read(2)
            if len(prefix) < 2:
                break
            ln = (prefix[0] << 8) | prefix[1]
            m = f.read(ln)
            if len(m) < ln:
                break
            seen += 1
            if m[0] == T_DIRECTORY and want in m:
                return (m[1] << 8) | m[2]
    return -1


def pack(kind: int, ref: int, ref2: int, shares: int, price: int, side: int) -> int:
    return ((kind << 195) | (ref << 131) | (ref2 << 67)
            | (shares << 35) | (price << 3) | (side << 2))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", type=Path)
    ap.add_argument("--vectors", type=Path, default=Path("tb/vectors"))
    ap.add_argument("--symbol", default="AAPL")
    ap.add_argument("--limit", type=int, default=0,
                    help="stop after this many source messages, 0 for the whole file")
    ap.add_argument("--sets", type=int, default=8192)
    ap.add_argument("--ways", type=int, default=16)
    args = ap.parse_args()

    want = args.symbol.ljust(8).encode()
    locate = find_locate(args.capture, want, 20000)
    if locate < 0:
        print(f"no stock directory entry for {args.symbol} in the first messages")
        return 1
    lo_hi, lo_lo = locate >> 8, locate & 0xFF
    print(f"{args.symbol} is stock locate {locate}")

    store = Store(args.sets, args.ways, 13, 17)
    out = []
    seen = kept = 0
    max_ref = max_shares = 0
    started = time.time()

    with args.capture.open("rb") as f:
        buf = f.read(CHUNK)
        pos = 0
        while True:
            if len(buf) - pos < 2:
                buf = buf[pos:] + f.read(CHUNK)
                pos = 0
                if len(buf) < 2:
                    break
            ln = (buf[pos] << 8) | buf[pos + 1]
            if len(buf) - pos - 2 < ln:
                buf = buf[pos:] + f.read(CHUNK)
                pos = 0
                if len(buf) - 2 < ln:
                    break
            m = pos + 2
            seen += 1

            # locate sits at offset 1 in every message type, so the reject is two
            # byte compares and the whole session streams past cheaply
            if buf[m + 1] == lo_hi and buf[m + 2] == lo_lo:
                kind = buf[m]
                if kind in KEEP:
                    ref = int.from_bytes(buf[m + 11:m + 19], "big")
                    if ref > max_ref:
                        max_ref = ref
                    if kind in ADDS:
                        side = 1 if buf[m + 19] == 0x42 else 0
                        shares = int.from_bytes(buf[m + 20:m + 24], "big")
                        price = int.from_bytes(buf[m + 32:m + 36], "big")
                        if shares > max_shares:
                            max_shares = shares
                        store.insert(ref, 0, side, price, shares)
                        out.append(pack(kind, ref, 0, shares, price, side))
                    elif kind in REDUCERS:
                        qty = int.from_bytes(buf[m + 19:m + 23], "big")
                        store.reduce(ref, qty)
                        out.append(pack(kind, ref, 0, qty, 0, 0))
                    elif kind == T_DELETE:
                        store.remove(ref)
                        out.append(pack(kind, ref, 0, 0, 0, 0))
                    else:
                        ref2 = int.from_bytes(buf[m + 19:m + 27], "big")
                        shares = int.from_bytes(buf[m + 27:m + 31], "big")
                        price = int.from_bytes(buf[m + 31:m + 35], "big")
                        if ref2 > max_ref:
                            max_ref = ref2
                        if shares > max_shares:
                            max_shares = shares
                        _s, _w, e = store.find(ref)
                        if e is not None:
                            store.remove(ref)
                            store.insert(ref2, e[1], e[2], price, shares)
                        out.append(pack(kind, ref, ref2, shares, price, 0))
                    kept += 1

            pos += 2 + ln
            if args.limit and seen >= args.limit:
                break

    args.vectors.mkdir(parents=True, exist_ok=True)
    (args.vectors / "book_records.hex").write_text(
        "".join(f"{v:051X}\n" for v in out), newline="\n")
    (args.vectors / "book_records.txt").write_text(
        f"{len(out)} {store.peak} {store.live}\n", newline="\n")

    took = time.time() - started
    print(f"messages scanned  {seen}  in {took:.0f} s")
    print(f"records kept      {kept}  -> book_records.hex")
    print(f"peak live orders  {store.peak}")
    print(f"final live        {store.live}")
    print(f"worst set fill    {store.peak_set} / {args.ways} ways")
    print(f"set overflows     {store.overflows}")
    print(f"lookup misses     {store.misses}")
    print(f"largest ref       {max_ref}")
    print(f"largest shares    {max_shares}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
