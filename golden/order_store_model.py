"""Reference model for order_store: the ref -> resting order map.

Structurally faithful, not just behavioural. It models the real sets, ways, tags
and the lowest-free-way allocation rule, so it predicts which way an order lands
in and how full each set gets. That makes it a check on the sizing decisions as
well as on the ITCH semantics.

Input is the parsed message stream already produced for the other stages,
tb/vectors/itch_expect.{hex,txt}. Records are filtered exactly as symbol_filter
does it: a symbol match for A/F, and everything else admitted because the message
carries no symbol to filter on.

Output tb/vectors/order_expect.txt, one line per emitted record:

    <seq> <type> <hit> <sym> <side> <price> <shares> <removed>

shares is the quantity resting before this message. A replace emits two lines,
the delete of the old ref then the insert of the new one, matching the two beat
output the RTL produces.
"""

from __future__ import annotations

import argparse
from pathlib import Path

SYMBOLS = [b"ZVZZT   ", b"SAP     ", b"GNW     ", b"RIO     "]

KEEP = {"A", "F", "E", "C", "X", "D", "U"}
ADDS = {"A", "F"}
REDUCERS = {"E", "C", "X"}


class Store:
    def __init__(self, sets: int, ways: int, tag_lo: int, tag_bits: int):
        self.sets = sets
        self.ways = ways
        self.mask = sets - 1
        self.shift = tag_lo
        self.tag_mask = (1 << tag_bits) - 1
        self.table = [[None] * ways for _ in range(sets)]
        self.live = 0
        self.peak = 0
        self.peak_set = 0
        self.overflows = 0
        self.misses = 0

    def index(self, ref: int) -> int:
        return (ref ^ (ref >> 13) ^ (ref >> 26)) & self.mask

    def tag(self, ref: int) -> int:
        return (ref >> self.shift) & self.tag_mask

    def find(self, ref: int):
        s = self.table[self.index(ref)]
        t = self.tag(ref)
        for w, e in enumerate(s):
            if e is not None and e[0] == t:
                return s, w, e
        return s, -1, None

    def insert(self, ref: int, sym: int, side: int, price: int, shares: int) -> bool:
        s = self.table[self.index(ref)]
        used = 0
        free = -1
        for w, e in enumerate(s):
            if e is None:
                if free < 0:
                    free = w
            else:
                used += 1
        if free < 0:
            self.overflows += 1
            return False
        s[free] = (self.tag(ref), sym, side, price, shares)
        self.live += 1
        if self.live > self.peak:
            self.peak = self.live
        if used + 1 > self.peak_set:
            self.peak_set = used + 1
        return True

    def remove(self, ref: int) -> bool:
        s, w, e = self.find(ref)
        if e is None:
            return False
        s[w] = None
        self.live -= 1
        return True

    def reduce(self, ref: int, qty: int):
        """returns (found, entry_before, removed)"""
        s, w, e = self.find(ref)
        if e is None:
            self.misses += 1
            return False, None, False
        left = e[4] - qty
        if left <= 0:
            s[w] = None
            self.live -= 1
            return True, e, True
        s[w] = (e[0], e[1], e[2], e[3], left)
        return True, e, False


def be(buf: bytes, base: int, off: int, width: int) -> int:
    return int.from_bytes(buf[base + off : base + off + width], "big")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", type=Path, default=Path("tb/vectors"))
    ap.add_argument("--sets", type=int, default=8192)
    ap.add_argument("--ways", type=int, default=16)
    ap.add_argument("--tag-lo", type=int, default=13)
    ap.add_argument("--tag-bits", type=int, default=20)
    ap.add_argument("--shares-bits", type=int, default=16)
    args = ap.parse_args()

    hexfile = args.vectors / "itch_expect.hex"
    txtfile = args.vectors / "itch_expect.txt"
    if not hexfile.exists() or not txtfile.exists():
        print(f"missing {hexfile} or {txtfile}")
        print("run scripts/mold_packetize.py first")
        return 1

    data = bytes(int(w, 16) for w in hexfile.read_text().split())
    wanted = {s for s in SYMBOLS}
    store = Store(args.sets, args.ways, args.tag_lo, args.tag_bits)

    lines = []
    kept = 0
    max_shares = 0
    max_ref = 0
    emitted = 0

    for raw in txtfile.read_text().splitlines():
        parts = raw.split()
        if len(parts) != 4:
            continue
        off, _length, seq, kind = int(parts[0]), int(parts[1]), int(parts[2]), parts[3]
        if kind not in KEEP:
            continue

        ref = be(data, off, 11, 8)
        max_ref = max(max_ref, ref)

        if kind in ADDS:
            if data[off + 24 : off + 32] not in wanted:
                continue
            kept += 1
            sym = SYMBOLS.index(data[off + 24 : off + 32])
            side = 1 if data[off + 19] == 0x42 else 0
            shares = be(data, off, 20, 4)
            price = be(data, off, 32, 4)
            max_shares = max(max_shares, shares)
            hit = store.insert(ref, sym, side, price, shares)
            lines.append(f"{seq} {kind} {int(hit)} {sym} {side} {price} {shares} 0")
            emitted += 1
            continue

        kept += 1

        if kind in REDUCERS:
            qty = be(data, off, 19, 4)
            found, e, gone = store.reduce(ref, qty)
            if found:
                lines.append(f"{seq} {kind} 1 {e[1]} {e[2]} {e[3]} {e[4]} {int(gone)}")
            else:
                lines.append(f"{seq} {kind} 0 0 0 0 0 0")
            emitted += 1

        elif kind == "D":
            _s, _w, e = store.find(ref)
            if e is None:
                store.misses += 1
                lines.append(f"{seq} D 0 0 0 0 0 0")
            else:
                store.remove(ref)
                lines.append(f"{seq} D 1 {e[1]} {e[2]} {e[3]} {e[4]} 1")
            emitted += 1

        elif kind == "U":
            new_ref = be(data, off, 19, 8)
            shares = be(data, off, 27, 4)
            price = be(data, off, 31, 4)
            max_shares = max(max_shares, shares)
            max_ref = max(max_ref, new_ref)
            _s, _w, e = store.find(ref)
            if e is None:
                store.misses += 1
                lines.append(f"{seq} U 0 0 0 0 0 0")
                emitted += 1
            else:
                sym, side = e[1], e[2]
                store.remove(ref)
                lines.append(f"{seq} U 1 {sym} {side} {e[3]} {e[4]} 1")
                hit = store.insert(new_ref, sym, side, price, shares)
                lines.append(f"{seq} U {int(hit)} {sym} {side} {price} {shares} 0")
                emitted += 2

    out = args.vectors / "order_expect.txt"
    out.write_text("\n".join(lines) + "\n")

    tag_span = 1 << (args.tag_lo + args.tag_bits)
    shares_span = 1 << args.shares_bits

    print(f"records kept      {kept}")
    print(f"lines emitted     {emitted}  -> {out}")
    print(f"peak live orders  {store.peak}")
    print(f"final live        {store.live}")
    print(f"worst set fill    {store.peak_set} / {args.ways} ways")
    print(f"set overflows     {store.overflows}")
    print(f"lookup misses     {store.misses}")
    print()
    print("field widths, measured against this vector set:")
    print(f"  largest ref     {max_ref}  (tag covers < {tag_span})"
          f"  {'OK' if max_ref < tag_span else 'TOO NARROW'}")
    print(f"  largest shares  {max_shares}  (field holds < {shares_span})"
          f"  {'OK' if max_shares < shares_span else 'TOO NARROW'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
