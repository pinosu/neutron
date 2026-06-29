#!/usr/bin/env python3
"""Derive the IBC-hooks intermediate sender address.

Algorithm (matches Cosmos SDK address.Hash + neutron x/ibc-hooks):
  typ  = sha256("ibc-wasm-hook-intermediary")          # 32 bytes
  key  = (channel + "/" + original_sender).encode()
  addr = sha256(typ || key)                            # 32 bytes, no truncation
  → bech32(prefix, addr)
"""
import hashlib
import sys

_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def _convertbits(data, frombits, tobits, pad=True):
    acc = 0; bits = 0; ret = []; maxv = (1 << tobits) - 1
    for val in data:
        acc = ((acc << frombits) | val) & 0xFFFFFF
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret

def _polymod(values):
    c = 1
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    for v in values:
        b = c >> 25
        c = ((c & 0x1FFFFFF) << 5) ^ v
        for i in range(5):
            c ^= GEN[i] if (b >> i) & 1 else 0
    return c

def _hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]

def _create_checksum(hrp, data):
    polymod = _polymod(_hrp_expand(hrp) + data + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]

def bech32_encode(hrp, data):
    """Encode raw bytes as bech32 with the given human-readable part."""
    bits5 = _convertbits(data, 8, 5)
    combined = bits5 + _create_checksum(hrp, bits5)
    return hrp + "1" + "".join(_CHARSET[d] for d in combined)

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} <prefix> <channel> <sender>")
    prefix, channel, sender = sys.argv[1], sys.argv[2], sys.argv[3]

    typ = hashlib.sha256(b"ibc-wasm-hook-intermediary").digest()   # sha256(SenderPrefix)
    key = (channel + "/" + sender).encode()
    addr = hashlib.sha256(typ + key).digest()                       # sha256(typ || key), 32 bytes

    print(bech32_encode(prefix, addr))
