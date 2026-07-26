#!/usr/bin/env python3
"""Wrap ITCH messages in MoldUDP64 packets and emit simulation vectors.

Input: Nasdaq ITCH BinaryFILE, a bare sequence of [2-byte BE length][message].

Outputs into --outdir:
  mold_bytes.hex    one byte per line, all emitted packets concatenated
  mold_packets.txt  per packet: <byte_offset> <byte_length> <sequence> <msg_count>
  itch_expect.hex   one byte per line, messages the deframer should emit
  itch_expect.txt   per message: <byte_offset> <byte_length> <sequence> <type_char>

Sequence numbers count messages, not packets: a header carries the sequence of
its first message. --drop exploits this -- dropped packets still consume their
sequence range, so the receiver sees a genuine gap.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

SESSION_LEN = 10
MOLD_HEADER_LEN = SESSION_LEN + 8 + 2
DEFAULT_MTU_PAYLOAD = 1472  # 1500 MTU - 20 IPv4 - 8 UDP
DEFAULT_MESSAGE_LIMIT = 100_000


def read_itch_messages(path: Path, limit: int | None):
    count = 0
    with path.open("rb") as handle:
        while True:
            prefix = handle.read(2)
            if not prefix:
                return
            if len(prefix) < 2:
                raise ValueError(f"truncated length prefix at {handle.tell() - len(prefix)}")
            (length,) = struct.unpack(">H", prefix)
            if length == 0:
                raise ValueError(f"zero-length message at {handle.tell() - 2}")
            message = handle.read(length)
            if len(message) < length:
                raise ValueError(
                    f"truncated message at {handle.tell() - len(message)}: "
                    f"wanted {length}, got {len(message)}"
                )
            yield message
            count += 1
            if limit is not None and count >= limit:
                return


def group_into_packets(messages, mtu_payload: int, max_count: int, start_seq: int):
    packets = []
    current: list[bytes] = []
    current_len = MOLD_HEADER_LEN
    sequence = start_seq

    for message in messages:
        block_len = 2 + len(message)
        if MOLD_HEADER_LEN + block_len > mtu_payload:
            raise ValueError(
                f"{len(message)}-byte message exceeds the {mtu_payload}-byte budget"
            )
        if current and (current_len + block_len > mtu_payload or len(current) >= max_count):
            packets.append((sequence, current))
            sequence += len(current)
            current, current_len = [], MOLD_HEADER_LEN
        current.append(message)
        current_len += block_len

    if current:
        packets.append((sequence, current))
    return packets


def serialise_packet(session: str, sequence: int, messages: list[bytes]) -> bytes:
    out = bytearray()
    out += session.encode("ascii").ljust(SESSION_LEN)[:SESSION_LEN]
    out += struct.pack(">Q", sequence)
    out += struct.pack(">H", len(messages))
    for message in messages:
        out += struct.pack(">H", len(message))
        out += message
    return bytes(out)


def write_hex(path: Path, data: bytes) -> None:
    with path.open("w", newline="\n") as handle:
        for byte in data:
            handle.write(f"{byte:02X}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", type=Path)
    parser.add_argument("--outdir", type=Path, default=Path("tb/vectors"))
    parser.add_argument("--session", default="TESTSESS")
    parser.add_argument("--start-seq", type=int, default=1)
    parser.add_argument("--mtu-payload", type=int, default=DEFAULT_MTU_PAYLOAD)
    parser.add_argument("--max-count", type=int, default=0xFFFE,
                        help="messages per packet; 0xFFFF is reserved for end-of-session")
    parser.add_argument("--limit", type=int, default=DEFAULT_MESSAGE_LIMIT,
                        help="stop after N messages; 0 means no limit")
    parser.add_argument("--drop", default=None,
                        help="comma-separated packet indices to drop, creating gaps")
    args = parser.parse_args()

    if not args.input.is_file():
        print(f"error: {args.input} not found", file=sys.stderr)
        return 1

    limit = None if args.limit == 0 else args.limit
    drops = {int(i) for i in args.drop.split(",") if i.strip()} if args.drop else set()

    messages = read_itch_messages(args.input, limit)
    packets = group_into_packets(messages, args.mtu_payload, args.max_count, args.start_seq)

    unknown = {i for i in drops if i >= len(packets)}
    if unknown:
        print(f"error: --drop names nonexistent packets: {sorted(unknown)}", file=sys.stderr)
        return 1

    args.outdir.mkdir(parents=True, exist_ok=True)

    stimulus, expected = bytearray(), bytearray()
    packet_lines, message_lines = [], []

    for index, (sequence, group) in enumerate(packets):
        if index in drops:
            continue
        blob = serialise_packet(args.session, sequence, group)
        packet_lines.append(f"{len(stimulus)} {len(blob)} {sequence} {len(group)}")
        stimulus += blob
        for offset, message in enumerate(group):
            kind = chr(message[0]) if 32 <= message[0] < 127 else "?"
            message_lines.append(
                f"{len(expected)} {len(message)} {sequence + offset} {kind}"
            )
            expected += message

    write_hex(args.outdir / "mold_bytes.hex", bytes(stimulus))
    write_hex(args.outdir / "itch_expect.hex", bytes(expected))
    (args.outdir / "mold_packets.txt").write_text("\n".join(packet_lines) + "\n", newline="\n")
    (args.outdir / "itch_expect.txt").write_text("\n".join(message_lines) + "\n", newline="\n")

    total = sum(len(group) for _, group in packets)
    print(f"read      {total} messages")
    print(f"packed    {len(packets)} packets "
          f"(avg {total / max(len(packets), 1):.1f} messages/packet)")
    print(f"emitted   {len(packets) - len(drops)} packets, {len(stimulus)} stimulus bytes")
    if drops:
        print(f"dropped   packets {sorted(drops)}")
    print(f"expected  {len(message_lines)} messages, {len(expected)} bytes")
    print(f"wrote     {args.outdir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
