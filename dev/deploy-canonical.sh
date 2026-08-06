#!/bin/bash

set -o errexit -o pipefail -o nounset

# Deploy the official contracts to a new chain at their canonical addresses.
#
# The addresses in `networks.json` can no longer be reproduced by compiling this repository (see
# https://github.com/cowprotocol/composable-cow/issues/93): the runtime code still matches, but the
# Solidity metadata hash embedded in the bytecode changed, and that hash is part of the `CREATE2`
# preimage. Recompiling therefore yields different addresses.
#
# Instead of recompiling, this script replays the exact initcode of the existing deployments,
# recorded under `canonical/`. Same initcode, same salt and same deployer give the same address on
# every EVM chain, so a new chain ends up matching all the others.

repo_root_dir="$(git rev-parse --show-toplevel)"
canonical_dir="$repo_root_dir/canonical"
manifest="$canonical_dir/manifest.json"

# The deterministic deployment proxy. It is a 69-byte contract that reads its calldata as
# `salt ++ initcode`, `CREATE2`s it and returns the address. It lives at the same address on most
# chains because it is deployed with a keyless (pre-signed) transaction.
deployer=0x4e59b44847b379578588920cA78FbF26c0B4956C

broadcast=false
rpc_url=${ETH_RPC_URL:-}

usage() {
  cat <<'USAGE'
Usage: dev/deploy-canonical.sh [--rpc-url URL] [--broadcast]

Without --broadcast the script only reports what it would do; nothing is sent.

Environment:
  ETH_RPC_URL   used when --rpc-url is not given
  PRIVATE_KEY   deployer key, required with --broadcast
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc-url) rpc_url=$2; shift 2 ;;
    --broadcast) broadcast=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$rpc_url" ]]; then
  echo "Error: no RPC endpoint. Pass --rpc-url or set ETH_RPC_URL." >&2
  exit 1
fi

if [[ "$broadcast" == true && -z "${PRIVATE_KEY:-}" ]]; then
  echo "Error: PRIVATE_KEY must be set to broadcast." >&2
  exit 1
fi

# `cast code` prints "0x" for an address with no code. An unreachable RPC makes it fail instead, and
# the two must not be confused: treating an RPC error as "no code" would report every contract as
# missing and, with --broadcast, redeploy contracts that already exist.
code_at() {
  local address=$1 code
  if ! code=$(cast code "$address" --rpc-url "$rpc_url" 2>&1); then
    echo "Error: could not read code at $address." >&2
    echo "       $code" >&2
    exit 1
  fi
  printf '%s' "$code"
}

if ! chain_id=$(cast chain-id --rpc-url "$rpc_url" 2>&1); then
  echo "Error: could not reach the RPC endpoint at $rpc_url." >&2
  echo "       $chain_id" >&2
  exit 1
fi
echo "Chain id: $chain_id"

# The canonical addresses are only reachable through this specific deployer, because its address is
# part of the `CREATE2` preimage. Deploying without it would silently produce different addresses.
if [[ "$(code_at "$deployer")" == "0x" ]]; then
  cat >&2 <<EOF
Error: the deterministic deployment proxy is not present at $deployer on chain $chain_id.

The canonical addresses cannot be reproduced without it. Deploy it first by broadcasting its
keyless transaction, then re-run this script:
  https://github.com/Arachnid/deterministic-deployment-proxy
EOF
  exit 1
fi
echo "Deterministic deployment proxy: present"

# Recompute every address from the recorded initcode before touching the chain. This catches a
# corrupted or hand-edited `canonical/` directory, which would otherwise deploy the wrong code.
echo
echo "Verifying recorded initcode..."
while read -r name; do
  salt=$(jq -r --arg n "$name" '.[$n].salt' "$manifest")
  expected=$(jq -r --arg n "$name" '.[$n].address' "$manifest")
  initcode=$(cat "$canonical_dir/$name.initcode")
  computed=$(cast create2 --deployer "$deployer" --salt "$salt" --init-code "$initcode" | tail -1)
  if [[ "$(tr 'A-Z' 'a-z' <<<"$computed")" != "$(tr 'A-Z' 'a-z' <<<"$expected")" ]]; then
    echo "Error: $name initcode does not produce its canonical address." >&2
    echo "       expected $expected, computed $computed" >&2
    exit 1
  fi
done < <(jq -r 'keys[]' "$manifest")
echo "All recorded initcode matches the canonical addresses."

echo
deployed=0
skipped=0
while read -r name; do
  salt=$(jq -r --arg n "$name" '.[$n].salt' "$manifest")
  address=$(jq -r --arg n "$name" '.[$n].address' "$manifest")
  initcode=$(cat "$canonical_dir/$name.initcode")

  if [[ "$(code_at "$address")" != "0x" ]]; then
    printf '%-30s %s  already deployed\n' "$name" "$address"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "$broadcast" != true ]]; then
    printf '%-30s %s  would deploy\n' "$name" "$address"
    continue
  fi

  printf '%-30s %s  deploying...\n' "$name" "$address"
  cast send "$deployer" "0x${salt#0x}${initcode#0x}" \
    --rpc-url "$rpc_url" --private-key "$PRIVATE_KEY" >/dev/null

  # A call to the proxy cannot revert loudly on every failure mode, so confirm the code landed
  # rather than trusting the transaction receipt.
  if [[ "$(code_at "$address")" == "0x" ]]; then
    echo "Error: $name did not appear at $address after broadcasting." >&2
    exit 1
  fi
  printf '%-30s %s  deployed\n' "$name" "$address"
  deployed=$((deployed + 1))
done < <(jq -r 'keys[]' "$manifest")

echo
if [[ "$broadcast" != true ]]; then
  echo "Dry run. Re-run with --broadcast to send the transactions."
else
  echo "Deployed $deployed contract(s), skipped $skipped already present."
  echo "Record the new addresses by regenerating networks.json (see the readme)."
fi
