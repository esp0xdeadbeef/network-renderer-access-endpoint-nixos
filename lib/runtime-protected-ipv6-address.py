#!/usr/bin/env python3
"""Derive and optionally assign one protected runtime IPv6 endpoint address."""

from __future__ import annotations

import argparse
import ipaddress
import subprocess
import sys


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"runtime protected IPv6 address: {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--delegated-prefix-length", required=True, type=int)
    parser.add_argument("--tenant-prefix-length", required=True, type=int)
    parser.add_argument("--slot", required=True, type=int)
    parser.add_argument("--interface-identifier", required=True)
    parser.add_argument("--target-prefix-length", required=True, type=int)
    output = parser.add_mutually_exclusive_group(required=True)
    output.add_argument("--print", action="store_true", dest="print_address")
    output.add_argument("--assign-interface")
    parser.add_argument("--ip-command")
    return parser.parse_args()


def derive(args: argparse.Namespace) -> str:
    try:
        with open(args.source, encoding="utf-8") as source:
            raw = source.read().strip()
        delegated = ipaddress.ip_network(raw, strict=True)
    except (OSError, ValueError):
        fail("protected source is missing or invalid")

    if delegated.version != 6:
        fail("protected source family is not IPv6")
    if delegated.prefixlen != args.delegated_prefix_length:
        fail("protected source prefix length does not match the contract")
    if not 0 <= args.delegated_prefix_length <= args.tenant_prefix_length <= 64:
        fail("delegated or tenant prefix length is invalid")
    if args.target_prefix_length != 128:
        fail("target prefix length must be 128")

    slot_bits = args.tenant_prefix_length - args.delegated_prefix_length
    if args.slot < 0 or args.slot >= (1 << slot_bits):
        fail("tenant slot is outside the delegated prefix")

    try:
        iid_text = args.interface_identifier
        if "::" not in iid_text and iid_text.count(":") == 3:
            iid_text = f"::{iid_text}"
        iid = int(ipaddress.IPv6Address(iid_text))
    except ValueError:
        fail("interface identifier is invalid")
    if iid >= (1 << 64):
        fail("interface identifier exceeds 64 bits")

    tenant_shift = 128 - args.tenant_prefix_length
    tenant_base = int(delegated.network_address) | (args.slot << tenant_shift)
    return f"{ipaddress.IPv6Address(tenant_base | iid)}/{args.target_prefix_length}"


def main() -> None:
    args = parse_args()
    address = derive(args)
    if args.print_address:
        print(address)
        return
    if not args.ip_command:
        fail("--ip-command is required when assigning an address")
    subprocess.run(
        [args.ip_command, "-6", "address", "replace", address, "dev", args.assign_interface],
        check=True,
    )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError:
        print("runtime protected IPv6 address: address assignment failed", file=sys.stderr)
        raise SystemExit(1)
