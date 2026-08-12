#!/bin/bash

set -o errexit -o pipefail -o nounset

# Recompute every canonical CREATE2 address from its recorded salt and initcode and compare it with
# the manifest. Offline: no RPC, no key. See `canonical/README.md` for why these files exist.

repo_root_dir="$(git rev-parse --show-toplevel)"
canonical_dir="$repo_root_dir/canonical"
initcode_dir="$canonical_dir/initcode"
manifest="$canonical_dir/manifest.json"

# Deterministic deployment proxy: its address is part of the CREATE2 preimage.
deployer=0x4e59b44847b379578588920cA78FbF26c0B4956C

lowercase() { tr 'A-Z' 'a-z' <<<"$1"; }

# Iterates over all keys in the manifest.json
while read -r name; do
  if [[ ! -f "$initcode_dir/$name.initcode" ]]; then
    echo "Error: $name is in the manifest but has no initcode file." >&2
    exit 1
  fi
  salt=$(jq -r --arg n "$name" '.[$n].salt' "$manifest")
  expected=$(jq -r --arg n "$name" '.[$n].address' "$manifest")
  initcode=$(cat "$initcode_dir/$name.initcode")

  # Compute the CREATE2
  computed=$(cast create2 --deployer "$deployer" --salt "$salt" --init-code "$initcode" | tail -1)

  # Ensure the computed CREATE2 address matches the expected address in the manifest
  if [[ "$(lowercase "$computed")" != "$(lowercase "$expected")" ]]; then
    echo "Error: $name initcode does not produce its canonical address." >&2
    echo "       expected $expected, computed $computed" >&2
    exit 1
  fi
done < <(jq -r 'keys[]' "$manifest")

# Ensure all initcode files have corresponding entries in the manifest
while read -r file; do
  name=$(basename "$file" .initcode)
  if [[ "$(jq -r --arg n "$name" 'has($n)' "$manifest")" != true ]]; then
    echo "Error: $name.initcode has no manifest entry." >&2
    exit 1
  fi
done < <(find "$initcode_dir" -name '*.initcode')

echo "All recorded initcode matches the canonical addresses."
