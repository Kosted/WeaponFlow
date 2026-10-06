"""Find simple ASCII names with a requested Stingray hash32 field ID.

Stingray's hash32 is the high half of MurmurHash64A with seed zero.  A field
name need only collide in that half for game_object_field's 32-bit lookup.
This script is offline tooling; no game process or game files are touched.
"""

from __future__ import annotations

import argparse

MASK = (1 << 64) - 1
M = 0xC6A4A7935BD1E995
M_INV = pow(M, -1, 1 << 64)


def hash64(data: bytes) -> int:
    value = (len(data) * M) & MASK
    index = 0
    while index + 8 <= len(data):
        key = int.from_bytes(data[index:index + 8], "little")
        key = (key * M) & MASK
        key ^= key >> 47
        key = (key * M) & MASK
        value ^= key
        value = (value * M) & MASK
        index += 8
    tail = data[index:]
    if tail:
        value ^= int.from_bytes(tail, "little")
        value = (value * M) & MASK
    value ^= value >> 47
    value = (value * M) & MASK
    value ^= value >> 47
    return value


def hash32(data: bytes) -> int:
    return hash64(data) >> 32


def collision_for(field_id: int) -> str:
    """Invert the 8-byte hash with a freely chosen low half of the output."""
    if not 0 <= field_id < (1 << 32):
        raise ValueError("field_id must be unsigned 32-bit")
    allowed = set(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    for low in range(1 << 32):
        value = (field_id << 32) | low
        value ^= value >> 47
        value = (value * M_INV) & MASK
        value ^= value >> 47
        value = (value * M_INV) & MASK
        key = value ^ ((8 * M) & MASK)
        key = (key * M_INV) & MASK
        key ^= key >> 47
        key = (key * M_INV) & MASK
        data = key.to_bytes(8, "little")
        if all(byte in allowed for byte in data):
            if hash32(data) != field_id:
                raise AssertionError("inverse hash failed")
            return data.decode("ascii")
    raise RuntimeError("no printable collision found")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("field_ids", nargs="+", type=lambda value: int(value, 16))
    args = parser.parse_args()
    for field_id in args.field_ids:
        print(f"{field_id:08x} {collision_for(field_id)}")


if __name__ == "__main__":
    main()
