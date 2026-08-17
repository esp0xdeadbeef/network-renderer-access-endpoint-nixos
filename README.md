# network-renderer-access-endpoint-nixos

`network-renderer-access-endpoint-nixos` materializes the **client side** of a
NixOS realization from the validated canonical bundle.

A *client* in this renderer's contract is any modeled endpoint that **consumes**
addressing from an access space, whether that endpoint is:

- a host's own client leg (for example a router host's management interface on
  an access VLAN), or
- a contained client workload (a container that is a DHCP/SLAAC/static client of
  an access space).

It is not the access role. The access role owns the DHCP server, router
advertisements, resolver advertisement, and gateway behavior for the access
space; that role is rendered by `network-renderer-nixos`. This renderer only
emits the endpoint that asks for an address.

## Purpose

- Render the client half of access-space addressing: DHCP, SLAAC, or an explicit
  static assignment, for hosts and containers alike.
- Keep the host configuration thin. A host selects this renderer and imports its
  output; it does not hand-write client network units, validation hooks, or
  realization logic locally.
- Render exactly the requested scope: one host, and when the model carries a
  single client or a named client, that client.

## Pipeline

```text
network-labs (intent + inventory)
  ↓
network-compiler → network-forwarding-model
  ↓
network-control-plane-model (CPM)
  ↓
network-realization-model → validated canonical realization bundle
  ↓
this renderer (client-side NixOS artifacts)
```

The renderer consumes the validated canonical bundle. It does not re-read raw
`intent.nix`, `inventory*.nix`, protected values, or runtime files to rediscover
clients.

## Contracts

- **Canonical input only.** Client records, their assignment mode, their access
  space, and their addressing come from the validated bundle.
- **Client-only authority.** The renderer may materialize a client's interface,
  address, gateway, DNS servers, and container/bridge attachment. It may not
  provision a DHCP server, router advertisement, DNS service, NAT, gateway
  behavior, forwarding, or firewall policy for an access space.
- **No policy invention.** It does not create allow rules, routes, or exposure
  from names, filenames, or defaults.
- **Fail closed.** A missing or ambiguous client record fails with a diagnostic
  that names the owning upstream contract, instead of being repaired locally.
- **Platform-native.** Client addressing uses NixOS and systemd-networkd
  primitives (network units, containers, bridge/VLAN plumbing), not bespoke
  services.

## What it renders

- A host client leg: the host's own bridge or VLAN interface as a
  `DHCP=ipv4` / `IPv6AcceptRA=yes` client, or as a modeled static client.
- A contained client: a NixOS container attached to an access bridge as a
  DHCP/SLAAC/static client.
- The L2 plumbing required to attach that client to its access bridge.

## What it must not render

- The access role's DHCP/DHCPv6 server, RA, resolver advertisement, or gateway.
- Tenant, service, or management policy, DNS authority, NAT/NAT66, routes, or
  firewall rules.
- A client that is not present in the validated bundle.
- Credentials or SSH authorized keys. Secret delivery and access identities are
  platform-binding or secret-management concerns, not renderer output.

## Scoped rendering

The renderer accepts a host scope and, when applicable, a client scope. If the
model contains a single client, rendering that client must be possible without
materializing unrelated clients, tenants, or sites.

## API

The flake exports:

| Export | Description |
|--------|-------------|
| `libBySystem.<system>.renderer.hostModule` | Standard renderer interface consuming a validated bundle and platform binding |
| `libBySystem.<system>.renderer.hostModuleFromPaths` | Path-based interface for renderer-local tests and fixtures only |

## Tests

Run the repo-local tests before claiming conformance:

```bash
bash tests/run.sh
```

Tests cover the client-materialization boundary: canonical-bundle-only input,
host and container client legs, scoped output, fail-closed missing records, and
the prohibition on access-role authority (no DHCP server, DNS, NAT, gateway,
policy invention, or credential injection).
