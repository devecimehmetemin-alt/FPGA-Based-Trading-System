#!/usr/bin/env python3
"""Wrap MoldUDP64 packets in UDP/IPv4/Ethernet-II frames and emit sim vectors.

Input: the vectors mold_packetize.py wrote --

  mold_bytes.hex    one byte per line, all Mold packets concatenated
  mold_packets.txt  per packet: <byte_offset> <byte_length> <sequence> <msg_count>

Reading those instead of the raw ITCH file means packet boundaries, sequence
numbers, and any gaps --drop created upstream carry through untouched.

Outputs into --outdir:
  eth_bytes.hex     one byte per line, all emitted frames concatenated
  eth_frames.txt    per frame: <frame_offset> <frame_len> <payload_offset>
                    <payload_len> <sequence> <msg_count> <fcs_state>

payload_offset is relative to the start of the frame, so a testbench can check
the deframer's output against mold_bytes.hex without recomputing header sizes.
"""

from __future__ import annotations

import argparse
import ipaddress
import struct
import sys
import zlib
from pathlib import Path

ETH_HEADER_LEN = 14
IPV4_HEADER_LEN = 20
UDP_HEADER_LEN = 8
FCS_LEN = 4
MIN_FRAME_LEN = 60  # 64 on the wire, minus the FCS
ETHERTYPE_IPV4 = 0x0800
IPPROTO_UDP = 17
PREAMBLE = bytes([0x55] * 7) + bytes([0xD5])

DEFAULT_DST_IP = "233.54.12.111"  # a real Nasdaq TotalView-ITCH group
DEFAULT_SRC_IP = "10.0.0.1"
DEFAULT_DST_PORT = 26477
DEFAULT_SRC_PORT = 50000
DEFAULT_SRC_MAC = "02:00:00:00:00:01"
DEFAULT_MTU = 1500


def read_hex_bytes(path: Path) -> bytes:
    out = bytearray()
    with path.open("r") as handle:
        for number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                value = int(text, 16)
            except ValueError:
                raise ValueError(f"{path}:{number}: {text!r} is not a hex byte") from None
            if not 0 <= value <= 0xFF:
                raise ValueError(f"{path}:{number}: {text!r} does not fit in a byte")
            out.append(value)
    return bytes(out)


def read_packet_index(path: Path):
    packets = []
    with path.open("r") as handle:
        for number, line in enumerate(handle, start=1):
            fields = line.split()
            if not fields:
                continue
            if len(fields) != 4:
                raise ValueError(f"{path}:{number}: wanted 4 fields, got {len(fields)}")
            offset, length, sequence, count = (int(f) for f in fields)
            packets.append((offset, length, sequence, count))
    return packets


def parse_mac(text: str) -> bytes:
    parts = text.replace("-", ":").split(":")
    if len(parts) != 6:
        raise ValueError(f"{text!r} is not a 6-octet MAC address")
    return bytes(int(part, 16) for part in parts)


def multicast_mac_for(address: ipaddress.IPv4Address) -> bytes:
    """RFC 1112: 01:00:5E plus the low 23 bits of the group address."""
    low = int(address) & 0x7FFFFF
    return bytes([0x01, 0x00, 0x5E, low >> 16, (low >> 8) & 0xFF, low & 0xFF])


def checksum16(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    total = 0
    for (word,) in struct.iter_unpack(">H", data):
        total += word
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def build_udp(src_ip, dst_ip, src_port: int, dst_port: int,
              payload: bytes, checksum: bool) -> bytes:
    length = UDP_HEADER_LEN + len(payload)
    header = struct.pack(">HHHH", src_port, dst_port, length, 0)
    if not checksum:
        return header + payload

    pseudo = src_ip.packed + dst_ip.packed + struct.pack(">BBH", 0, IPPROTO_UDP, length)
    value = checksum16(pseudo + header + payload)
    # A computed zero is transmitted as all ones; zero itself means "no checksum".
    if value == 0:
        value = 0xFFFF
    return struct.pack(">HHHH", src_port, dst_port, length, value) + payload


def build_ipv4(src_ip, dst_ip, identifier: int, ttl: int, payload: bytes) -> bytes:
    total_length = IPV4_HEADER_LEN + len(payload)
    header = struct.pack(
        ">BBHHHBBH4s4s",
        0x45,               # version 4, 5 32-bit words of header
        0x00,               # DSCP / ECN
        total_length,
        identifier & 0xFFFF,
        0x0000,             # no flags, no fragment offset
        ttl,
        IPPROTO_UDP,
        0x0000,             # checksum placeholder
        src_ip.packed,
        dst_ip.packed,
    )
    value = checksum16(header)
    return header[:10] + struct.pack(">H", value) + header[12:] + payload


def build_frame(dst_mac: bytes, src_mac: bytes, ip_payload: bytes,
                fcs: bool, corrupt: bool, preamble: bool):
    """Return (frame_bytes, payload_offset_within_frame)."""
    body = struct.pack(">6s6sH", dst_mac, src_mac, ETHERTYPE_IPV4) + ip_payload
    if len(body) < MIN_FRAME_LEN:
        body += bytes(MIN_FRAME_LEN - len(body))

    frame = bytearray(body)
    if fcs:
        value = zlib.crc32(body) & 0xFFFFFFFF
        if corrupt:
            value ^= 0xFFFFFFFF
        frame += struct.pack("<I", value)

    offset = ETH_HEADER_LEN + IPV4_HEADER_LEN + UDP_HEADER_LEN
    if preamble:
        frame = bytearray(PREAMBLE) + frame
        offset += len(PREAMBLE)
    return bytes(frame), offset


def write_hex(path: Path, data: bytes) -> None:
    with path.open("w", newline="\n") as handle:
        for byte in data:
            handle.write(f"{byte:02X}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--vectors", type=Path, default=Path("tb/vectors"),
                        help="directory holding mold_bytes.hex and mold_packets.txt")
    parser.add_argument("--outdir", type=Path, default=None,
                        help="where to write the frame vectors; defaults to --vectors")
    parser.add_argument("--src-mac", default=DEFAULT_SRC_MAC)
    parser.add_argument("--dst-mac", default=None,
                        help="defaults to the RFC 1112 mapping of --dst-ip when it is multicast")
    parser.add_argument("--src-ip", default=DEFAULT_SRC_IP)
    parser.add_argument("--dst-ip", default=DEFAULT_DST_IP)
    parser.add_argument("--src-port", type=int, default=DEFAULT_SRC_PORT)
    parser.add_argument("--dst-port", type=int, default=DEFAULT_DST_PORT)
    parser.add_argument("--ttl", type=int, default=64)
    parser.add_argument("--ip-id", type=int, default=1,
                        help="IPv4 identification of the first frame; increments per frame")
    parser.add_argument("--mtu", type=int, default=DEFAULT_MTU,
                        help="largest IP packet allowed; oversize input is an error, not a fragment")
    parser.add_argument("--no-fcs", action="store_true",
                        help="omit the CRC-32 trailer, for a MAC that appends its own")
    parser.add_argument("--no-udp-checksum", action="store_true",
                        help="transmit a zero UDP checksum instead of computing one")
    parser.add_argument("--preamble", action="store_true",
                        help="prepend the 7-byte preamble and SFD to every frame")
    parser.add_argument("--corrupt-fcs", default=None,
                        help="comma-separated frame indices whose FCS is inverted")
    args = parser.parse_args()

    outdir = args.outdir if args.outdir is not None else args.vectors
    bytes_path = args.vectors / "mold_bytes.hex"
    index_path = args.vectors / "mold_packets.txt"
    for path in (bytes_path, index_path):
        if not path.is_file():
            print(f"error: {path} not found; run mold_packetize.py first", file=sys.stderr)
            return 1

    try:
        src_ip = ipaddress.IPv4Address(args.src_ip)
        dst_ip = ipaddress.IPv4Address(args.dst_ip)
        src_mac = parse_mac(args.src_mac)
        dst_mac = parse_mac(args.dst_mac) if args.dst_mac else None
        stimulus = read_hex_bytes(bytes_path)
        packets = read_packet_index(index_path)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if dst_mac is None:
        if not dst_ip.is_multicast:
            print(f"error: --dst-ip {dst_ip} is not multicast, so --dst-mac is required",
                  file=sys.stderr)
            return 1
        dst_mac = multicast_mac_for(dst_ip)

    if args.no_fcs and args.corrupt_fcs:
        print("error: --corrupt-fcs needs an FCS to corrupt", file=sys.stderr)
        return 1
    corrupt = {int(i) for i in args.corrupt_fcs.split(",") if i.strip()} if args.corrupt_fcs else set()
    unknown = {i for i in corrupt if i >= len(packets)}
    if unknown:
        print(f"error: --corrupt-fcs names nonexistent frames: {sorted(unknown)}", file=sys.stderr)
        return 1

    budget = args.mtu - IPV4_HEADER_LEN - UDP_HEADER_LEN
    outdir.mkdir(parents=True, exist_ok=True)

    wire = bytearray()
    frame_lines = []

    for index, (offset, length, sequence, count) in enumerate(packets):
        if offset + length > len(stimulus):
            print(f"error: packet {index} runs past the end of {bytes_path}", file=sys.stderr)
            return 1
        payload = stimulus[offset:offset + length]
        if len(payload) > budget:
            print(f"error: packet {index} is {len(payload)} bytes, over the "
                  f"{budget}-byte budget for a {args.mtu}-byte MTU", file=sys.stderr)
            return 1

        datagram = build_udp(src_ip, dst_ip, args.src_port, args.dst_port,
                             payload, not args.no_udp_checksum)
        packet = build_ipv4(src_ip, dst_ip, args.ip_id + index, args.ttl, datagram)
        frame, payload_offset = build_frame(dst_mac, src_mac, packet,
                                            not args.no_fcs, index in corrupt, args.preamble)

        state = "bad" if index in corrupt else "ok"
        frame_lines.append(
            f"{len(wire)} {len(frame)} {payload_offset} {len(payload)} "
            f"{sequence} {count} {state}"
        )
        wire += frame

    write_hex(outdir / "eth_bytes.hex", bytes(wire))
    (outdir / "eth_frames.txt").write_text("\n".join(frame_lines) + "\n", newline="\n")

    payload_bytes = sum(length for _, length, _, _ in packets)
    print(f"read      {len(packets)} Mold packets, {payload_bytes} payload bytes")
    print(f"framed    {len(frame_lines)} frames to "
          f"{dst_ip}:{args.dst_port} ({':'.join(f'{b:02x}' for b in dst_mac)})")
    print(f"emitted   {len(wire)} wire bytes "
          f"({len(wire) - payload_bytes} bytes of overhead)")
    if corrupt:
        print(f"corrupted FCS on frames {sorted(corrupt)}")
    print(f"wrote     {outdir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
