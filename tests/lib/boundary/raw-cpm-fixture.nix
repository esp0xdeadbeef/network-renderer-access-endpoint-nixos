# A raw control-plane-model artifact, used ONLY as INPUT to prove the canonical
# boundary rejects it.
#
# This lives under tests/ on purpose. `tests/test-raw-cpm-consumption.sh` scans
# implementation source for reads of the plain control-plane model, and states its
# own boundary: "`tests/` is excluded on purpose: a test may build a CPM as INPUT
# to prove the renderer rejects it". Keeping this fixture in flake.nix put a
# legitimate negative test inside the scanned set, where it read as the defect it
# exists to detect.
{
  control_plane_model = { };
}
