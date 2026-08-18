"""Reference model for price_level and book_update.

Runs the two stages that sit behind order_store, taking their input from the
deltas order_store_model.py already produces so each stage is checked against the
output of the one before it rather than against a separate parse.

price_level is modelled structurally, with the same fold, sets and ways, so the
model predicts set overflow as well as quantities. book_update is a sorted top
DEPTH ladder per side, best first, matching the register array in the RTL.

Reads  tb/vectors/order_expect.txt
Writes tb/vectors/level_expect.txt   <sym> <side> <price> <qty>
       tb/vectors/bbo_expect.txt     <sym> <bid_live> <bid_px> <bid_qty>
                                           <ask_live> <ask_px> <ask_qty>

A level line is emitted whenever price_level applies an update, which is what
drives lvl_valid. A bbo line is emitted only when the touched level is the best
one, which is what drives bbo_valid.
"""

from __future__ import annotations

import argparse
from pathlib import Path


class Levels:
    """hashed accumulator, one entry per live price level"""

    def __init__(self, sets: int, ways: int):
        self.sets = sets
        self.ways = ways
        self.idx_w = sets.bit_length() - 1
        self.mask = sets - 1
        self.table = [[None] * ways for _ in range(sets)]
        self.live = 0
        self.peak = 0
        self.peak_set = 0
        self.overflows = 0
        self.misses = 0

    def index(self, key: int) -> int:
        out = 0
        for i in range(0, 35, self.idx_w):
            out ^= (key >> i) & self.mask
        return out

    def apply(self, sym: int, side: int, price: int, delta: int):
        """returns (applied, qty) with qty 0 when the level was emptied"""
        if delta == 0:
            return False, 0
        key = (sym << 33) | (side << 32) | price
        s = self.table[self.index(key)]

        for w, e in enumerate(s):
            if e is not None and e[0] == key:
                total = e[1] + delta
                if total <= 0:
                    s[w] = None
                    self.live -= 1
                    return True, 0
                s[w] = (key, total)
                return True, total

        if delta < 0:
            self.misses += 1
            return False, 0

        used = sum(1 for e in s if e is not None)
        free = next((w for w, e in enumerate(s) if e is None), -1)
        if free < 0:
            self.overflows += 1
            return False, 0
        s[free] = (key, delta)
        self.live += 1
        self.peak = max(self.peak, self.live)
        self.peak_set = max(self.peak_set, used + 1)
        return True, delta


class Ladder:
    """top DEPTH levels per side, best first, so slot 0 is the BBO"""

    def __init__(self, depth: int):
        self.depth = depth
        self.side = {}
        self.degraded = False

    def rung(self, sym: int, side: int):
        return self.side.setdefault((sym, side), [])

    def apply(self, sym: int, side: int, price: int, qty: int):
        """returns True when slot 0 changed, which is what gates bbo_valid"""
        lad = self.rung(sym, side)
        gone = qty == 0
        pos = next((i for i, (p, _q) in enumerate(lad) if p == price), -1)

        if gone:
            if pos < 0:
                return False
            lad.pop(pos)
            return pos == 0

        if pos >= 0:
            lad[pos] = (price, qty)
            return pos == 0

        # bids rank high price first, asks low price first
        ins = self.depth
        for i, (p, _q) in enumerate(lad):
            if (price > p) if side else (price < p):
                ins = i
                break
        else:
            ins = len(lad)
        if ins >= self.depth:
            return False

        lad.insert(ins, (price, qty))
        if len(lad) > self.depth:
            lad.pop()
            self.degraded = True
        return ins == 0

    def best(self, sym: int, side: int):
        lad = self.rung(sym, side)
        if not lad:
            return 0, 0, 0
        return 1, lad[0][0], lad[0][1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", type=Path, default=Path("tb/vectors"))
    ap.add_argument("--sets", type=int, default=4096)
    ap.add_argument("--ways", type=int, default=8)
    ap.add_argument("--depth", type=int, default=8)
    args = ap.parse_args()

    src = args.vectors / "order_expect.txt"
    if not src.exists():
        print(f"missing {src}")
        print("run golden/order_store_model.py first")
        return 1

    levels = Levels(args.sets, args.ways)
    ladder = Ladder(args.depth)

    lvl_lines, bbo_lines = [], []
    fed = 0

    for raw in src.read_text().splitlines():
        p = raw.split()
        if len(p) != 9:
            continue
        sym, side, price, delta = int(p[3]), int(p[4]), int(p[5]), int(p[8])
        if delta == 0:
            continue
        fed += 1

        applied, qty = levels.apply(sym, side, price, delta)
        if not applied:
            continue
        lvl_lines.append(f"{sym} {side} {price} {qty}")

        if ladder.apply(sym, side, price, qty):
            bl, bp, bq = ladder.best(sym, 1)
            al, ap_, aq = ladder.best(sym, 0)
            bbo_lines.append(f"{sym} {bl} {bp} {bq} {al} {ap_} {aq}")

    (args.vectors / "level_expect.txt").write_text("\n".join(lvl_lines) + "\n")
    (args.vectors / "bbo_expect.txt").write_text("\n".join(bbo_lines) + "\n")

    print(f"deltas fed        {fed}")
    print(f"level updates     {len(lvl_lines)}  -> level_expect.txt")
    print(f"bbo updates       {len(bbo_lines)}  -> bbo_expect.txt")
    print(f"peak live levels  {levels.peak}")
    print(f"final live levels {levels.live}")
    print(f"worst set fill    {levels.peak_set} / {args.ways} ways")
    print(f"set overflows     {levels.overflows}")
    print(f"level misses      {levels.misses}")
    print(f"ladder degraded   {int(ladder.degraded)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
