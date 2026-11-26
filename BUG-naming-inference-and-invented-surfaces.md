# BUG: the management surface is inferred from a name, and defaulted when absent

`FS-310-HDS-010-SDS-010-SMS-120` ("Naming-Inference Detection") lists this renderer by
name, and the code it names is still here:

| line | what the renderer chooses |
| --- | --- |
| `lib/renderer.nix:483` | `uplinkName == "management"` classifies a role from a name |
| `lib/renderer.nix:489` | `else [ "mgmt" ]` supplies a bridge the model never named |
| `lib/renderer.nix:864` | the same name test again, in `isManagementUplink` |
| `lib/renderer.nix:1084` | `hostname "s-router-test-clients"` |
| `lib/renderer.nix:1086` | `mode or "test"`, contradicting its own comment |

The default is load-bearing, not cosmetic: `managementAssignmentNames` requires an endpoint
whose bridge is in `managementBridgeNames` **and** whose assignment is a management one, so
the invented `"mgmt"` decides which endpoints count as management.

## Why it was not fixed in place

Removing the fallback (`managementBridgeNames = managementUplinkBridgeNames`) and the name
test was tried and is *half* a fix: the renderer's own consistency check then fails —

```
FS-725-HDS-020-SDS-010-SMS-010: EMPTY_MANAGEMENT_ENDPOINT_INVENTORY:
  mgmt bridge is declared but no CPM endpointAssignment has role=management on mgmt bridge
```

because something else still declares a `mgmt` bridge for a fragment where no management
uplink is modeled. The two must move together: the bridge may exist only when the model says
so, and then the check has nothing to complain about.

## Required

1. The role comes from the modeled facts (`role`, `management`) only — never from the name.
2. No management uplink in the model means no management bridge, and no management endpoint
   set; the consistency check then rejects a model that declares one without the other.
3. `hostname` and `mode` must be taken from the model, or the render fails with a named
   diagnostic instead of choosing `s-router-test-clients` / `test`.
4. `FS-310-HDS-010-SDS-010-SMS-120` needs an SMT row. The module whose job is to catch this
   class has no executed check, which is how the pattern survived here.
