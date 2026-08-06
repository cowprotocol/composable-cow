#!/bin/bash

set -o errexit -o pipefail -o nounset

repo_root_dir="$(git rev-parse --show-toplevel)"
manual_file="$repo_root_dir/broadcast/networks-manual.json"

# Generate JSON from broadcast deployment files
generated=$(for deployment in "$repo_root_dir/broadcast/"*"/"*"/"*".json"; do
  # Extract chain ID from folder name
  chain_id=${deployment%/*}
  chain_id=${chain_id##*/}

  # Extract contract info per chain. `CREATE` is accepted alongside `CREATE2` because the
  # standalone `deploy_ComposableCowPoller.s.sol` omits the salt, so the existing Gnosis Chain
  # poller was deployed non-deterministically.
  jq --arg chainId "$chain_id" '
    .transactions[]
    | select(.transactionType == "CREATE" or .transactionType == "CREATE2")
    | select(.hash != null)
    | {(.contractName): {($chainId): {address: .contractAddress, transactionHash: .hash }}}
  ' <"$deployment"
  # When the same contract appears more than once, the last one wins: within a run, the latest
  # deployment; across runs, the path that sorts last (so `run-latest.json` beats `run-<timestamp>.json`).
done | jq --sort-keys --null-input 'reduce inputs as $item ({}; . *= $item)')

# Merge with manual file if it exists
if [[ -f "$manual_file" ]]; then
  # Validate that the manual file contains valid JSON
  if ! jq empty "$manual_file" 2>/dev/null; then
    echo "Error: $manual_file is not valid JSON." >&2
    exit 1
  fi

  jq --slurp --sort-keys 'reduce .[] as $item ({}; . *= $item)' \
    <(printf '%s' "$generated") "$manual_file"
else
  printf '%s\n' "$generated"
fi
