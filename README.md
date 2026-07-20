# network-renderer-access-endpoint-nixos

`network-renderer-access-endpoint-nixos` materializes NixOS endpoint fixture
containers from one validated canonical bundle. Canonical
`endpointAssignment` records remain the network authority; one optional
normalized endpoint platform-binding bundle may supply bounded target
mechanics. It is an
**emission stage only** in the s-router GAMP pipeline.

Migration, deviation, exception, transition, or temporary compatibility behavior
must be explicit in the README, tests, and owning layer before it is accepted.

## Spec Chain

| Layer | ID | Status |
|-------|----|--------|
| URS | — | Traced through FS in `GAMP/FS/README.md` |
| FS | FS-720 | OK |
| FS | FS-725 | OK — s-router-test-clients Host Non-Participation |
| FS | FS-983 | OK — Renderer Endpoint Fixture Data Boundary |
| HDS | FS-720-HDS-030 | OK — Client Address Assignment Source |
| SDS | FS-720-HDS-030-SDS-010 | OK — DHCP Address Assignment Source |
| SMS | FS-230-HDS-010-SDS-010-SMS-040 | Construction OK; cold-stage live proof pending — protected IPv6 service endpoint materialization |
| SMS | FS-720-HDS-010-SDS-025-SMS-010 | OK — DHCP Address-Assignment Source Module |
| SMS | FS-725-HDS-010-SDS-010-SMS-010 | OK — Host Non-Participation (SMT proven) |

## Pipeline

```text
network-labs (intent.nix + inventory-nixos.nix)
  ↓
network-compiler → network-forwarding-model
  ↓
network-control-plane-model (CPM) → network-realization-model → schema validation
  ↓
**this renderer** (NixOS test-client containers)
```

This renderer sits downstream of canonical schema validation and upstream of
NixOS host configuration. It consumes canonical `endpointAssignment` records and
emits NixOS container definitions for access endpoint test fixtures.

## Contract

### Canonical input
The controlled renderer API consumes data exclusively through the validated
canonical bundle. The retained path-building regression helper calls
`cpm.compileAndBuildFromPaths` to build the historical CPM model, then reads
`control_plane_model.data.<enterprise>.<site>.endpointAssignment` for endpoint
fixture records. Phase 2 (`buildContainersFromAssignment`) replaced the Phase 1
implementation that read raw inventory.

### Fail-closed
Missing CPM data must fail evaluation. Static endpoint fixtures throw on
missing `gateway4`. Unsupported assignment modes throw with a diagnostic naming
the endpoint and mode. A valid CPM output with zero endpoint assignments is a
no-endpoint fixture profile: the renderer emits no endpoint containers and does
not read raw inventory as a fallback.

### No defaults
The renderer does not supply hardcoded defaults for endpoint addresses, bridge
names, or assignment modes. Bridge names come from the `endpointAssignment`
`bridge` field (defaulting to tenant name only when bridge is explicitly empty —
the tenant name is a CPM-provided field, not a hardcoded string).

### No naming inference
All endpoint classification (static vs DHCP, address family, bridge attachment)
is driven by explicit CPM `endpointAssignment` record fields (`mode`, `static`,
`dhcp`). No interface name pattern matching, role-name inference, or tenant-name
parsing is used for policy derivation.

### No policy invention
The renderer does not create tenant policy, DNS service, NAT, routing rules, or
firewall policy on endpoint bridges. Bridge networks are pure L2 plumbing:
`DHCP = "no"`, `IPv6AcceptRA = false`, no IP addresses. The `access-endpoint-isolate-bridges`
service blocks endpoint bridge subnets from reaching the host management VLAN
— this is a host-isolation measure, not endpoint policy invention.

Endpoint containers are also policy-neutral. The renderer force-disables their
NixOS default firewall so that an endpoint-local default-deny verdict cannot
mask an explicitly modeled router-path result. It does not derive or install a
tuple-specific endpoint allow; the upstream router contract remains the only
network-policy authority exercised by the fixture.

## What it does

- Consumes CPM `endpointAssignment` records for static and DHCP endpoint fixtures.
- Materializes NixOS containers with explicit addresses, gateways, DNS servers,
  and bridge attachments.
- Creates L2 bridge networks and VLAN netdevs on the host (`s-router-test-clients`)
  for endpoint bridge attachment.
- Supports both `dhcp` and `static`/`static-only` assignment modes.
- Force-disables the endpoint-container default firewall without adding
  service-specific accepts, so live probes observe only modeled router policy.
- For an explicit CPM `runtimeAddressAssignments` record, mounts only the
  referenced `/run/secrets/...` source read-only into the selected endpoint and
  materializes its IPv6 `/128` after networking is online. The protected prefix
  is never evaluated by Nix or written to the store.
- Blocks endpoint bridge traffic from reaching the host management VLAN.

## What it MUST NOT do

Per FS-725 and FS-983:

- Must not read `intent.nix`, `inventory.nix`, or `inventory-nixos.nix` directly
  for endpoint assignment data — all data must come through CPM.
- Must not provision DHCP server, DNS service, NAT, gateway behavior, endpoint
  forwarding, endpoint firewall policy, or endpoint bridge IP addresses on the
  `s-router-test-clients` host.
- Must not inherit a default endpoint-container firewall that can mask modeled
  router behavior, and must not replace it with tuple-specific fixture policy.
- Must not walk tenant definitions, access-node assignments, address prefixes,
  or endpoint client lists from raw intent or inventory.
- Must not fall back to direct inventory import when CPM output is missing
  required fields — must report the gap as a missing upstream contract.

## API

The flake exports:

| Export | Description |
|--------|-------------|
| `libBySystem.<system>.renderer.canonical.hostModule` | Controlled renderer interface: accepts one validated `bundle`, optional `platformBinding`, and host parameters |
| `libBySystem.<system>.renderer.canonical.validateInput` | Common bundle, scope, target, and binding validation boundary |
| `libBySystem.<system>.renderer.hostModule` | Superseded direct-CPM regression interface; not current FS-166 evidence |
| `libBySystem.<system>.renderer.hostModuleFromPaths` | Superseded compatibility path builder; not current FS-166 evidence |

Example usage:

```nix
inputs.network-renderer-access-endpoint-nixos.libBySystem.${system}.renderer.canonical.hostModule {
  inherit bundle platformBinding;
  hostName = "s-router-test-clients";
  mode = "test";
}
```

## Tests

Run the repo-local tests before claiming conformance:

```bash
bash tests/run.sh
```

| Test | Covers |
|------|--------|
| `tests/FS-230-HDS-010-SDS-010-SMS-040-protected-runtime-service-address.sh` | Exact protected-source bind boundary, service-only `/128` materialization, public-probe isolation, SOPS ordering, synthetic derivation, and fail-closed invalid-prefix handling. |
| `tests/FS-725-HDS-010-SDS-010-SMS-010.sh` | 36 assertions, 8 SMS acceptance predicates: VLAN2 management reachability, endpoint bridges L2-only, no host-side participation, VLAN2/endpoint separation, no host compensation. 3 seeded negatives (DHCP injection, bridge IP injection, missing isolate-bridges service). |
| `tests/FS-720-HDS-010-SDS-010-SMS-050.sh` | 14 assertions, 4 SMS sub-module acceptance predicates: bridge netdev emission (SMS-050), bridge network configuration (SMS-020), dummy service deactivation (SMS-040), VLAN-tagged bridge networks (SMS-060). 2 seeded negatives (DHCPServer injection, bridge Address injection). |
