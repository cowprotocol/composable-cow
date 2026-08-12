#!/bin/bash

set -o errexit -o pipefail -o nounset

# Deploy the older contracts to a new chain at their official addresses, by replaying the initcode
# recorded in `canonical/`. See `canonical/README.md` for why this exists.

repo_root_dir="$(git rev-parse --show-toplevel)"
canonical_dir="$repo_root_dir/canonical"
initcode_dir="$canonical_dir/initcode"
manifest="$canonical_dir/manifest.json"

# Deterministic deployment proxy: takes `salt ++ initcode` as calldata and CREATE2s it.
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

# Fails loudly instead of returning "0x", so a broken RPC is never read as "nothing deployed here".
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

# Required: the deployer address is part of the CREATE2 preimage.
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

# Fail closed on a corrupted or hand-edited `canonical/` before touching the chain.
echo
echo "Verifying recorded initcode..."
bash "$repo_root_dir/dev/verify-canonical.sh"

echo
deployed=0
skipped=0
while read -r name; do
  salt=$(jq -r --arg n "$name" '.[$n].salt' "$manifest")
  address=$(jq -r --arg n "$name" '.[$n].address' "$manifest")
  initcode=$(cat "$initcode_dir/$name.initcode")

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

  # The proxy does not revert on every failure mode, so check rather than trust the receipt.
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
