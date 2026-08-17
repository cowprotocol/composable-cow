#!/bin/bash

set -o errexit -o pipefail -o nounset

repo_root_dir="$(git rev-parse --show-toplevel)"
manual_file="$repo_root_dir/broadcast/networks-manual.json"

# One record per deployed contract, oldest first, so the newest run wins the merge below. Ordering
# by run rather than by file path matters because several scripts deploy the same contract.
# `CREATE` is accepted alongside `CREATE2` because `deploy_ComposableCowPoller.s.sol` omits the
# salt, so the existing Gnosis Chain poller was deployed non-deterministically.
generated=$(jq --slurp --sort-keys '
  # Foundry recorded seconds in older runs and milliseconds in newer ones.
  def ran_at: .timestamp | if . > 100000000000 then . / 1000 else . end;

  [ .[]
    | ran_at as $ran_at
    | (.chain | tostring) as $chain
    | (.receipts | INDEX(.transactionHash)) as $receipts
    | .transactions[]
    | select(.transactionType == "CREATE" or .transactionType == "CREATE2")
    | select(.hash != null)
    # A run that reverted, or never landed, must not become the published deployment. Runs that
    # predate the receipt log are listed in networks-manual.json instead.
    | select($receipts[.hash].status == "0x1")
    | [$ran_at, {(.contractName): {($chain): {address: .contractAddress, transactionHash: .hash}}}]
  ]
  # `sort_by` is stable, so a run keeps its own transaction order and the later one wins.
  | sort_by(.[0]) | map(.[1]) | reduce .[] as $item ({}; . *= $item)
' "$repo_root_dir/broadcast/"*"/"*"/"*".json")

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
