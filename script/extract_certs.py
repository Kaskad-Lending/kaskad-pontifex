#!/usr/bin/env python3
"""Print CERT_CHAIN for RegisterEnclave.s.sol: the attestation's CA bundle (root excluded) plus the leaf certificate, comma-separated 0x hex, in verification order."""
import sys
from pathlib import Path

import cbor2


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: extract_certs.py <attestation.hex | 0xHEX>")
    arg = sys.argv[1]
    raw = Path(arg).read_text().strip() if Path(arg).is_file() else arg
    doc = bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)
    cose = cbor2.loads(doc)
    if isinstance(cose, cbor2.CBORTag):
        cose = cose.value
    payload = cbor2.loads(cose[2])
    chain = list(payload["cabundle"][1:]) + [payload["certificate"]]
    print(",".join("0x" + cert.hex() for cert in chain))


if __name__ == "__main__":
    main()
