#!/bin/bash

set -o errexit -o pipefail -o nounset

repo_root_dir="$(git rev-parse --show-toplevel)"
manual_file="$repo_root_dir/broadcast/networks-manual.json"

# Some networks can't be deployed to with the deployment scripts (see
# https://github.com/cowprotocol/composable-cow/issues/93), so they have no broadcast artifacts to
# read from. Those are recorded by hand in `broadcast/networks-manual.json`, which has the same
# shape as `networks.json` and is merged on top of whatever the broadcast files produce.

# Build the JSON out of the broadcast deployment artifacts.
generated=$(for deployment in "$repo_root_dir/broadcast/"*"/"*"/"*".json"; do
  # The subfolder name is the chain id
  chain_id=${deployment%/*}
  chain_id=${chain_id##*/}

  # First, every single deployment is formatted as if it had its own networks.json.
  # `CREATE` is accepted alongside `CREATE2` because not every contract is deployed
  # deterministically: `deploy_ComposableCowPoller.s.sol` takes a constructor argument and is
  # deployed without a salt.
  jq --arg chainId "$chain_id" '
    .transactions[]
    | select(.transactionType == "CREATE" or .transactionType == "CREATE2")
    | select(.hash != null)
    | {(.contractName): {($chainId): {address: .contractAddress, transactionHash: .hash }}}
  ' <"$deployment"
done \
  | # Then, all these single-contract single-chain-id networks.jsons are merged. Note: in case the same contract is
    # deployed twice in the same script run, the last deployed contract takes priority.
    # If the same contract is deployed twice in different runs, the address in the file path that comes latest in
    # alphabetical order takes priority. For example, a contract in `broadcast/Deployment10/*` is overwritten by
    # one with the same name from `broadcast/Deployment2/*`. `run-latest.json` sorts after any `run-<timestamp>.json`,
    # so the most recent run of a script wins.
    jq --sort-keys --null-input 'reduce inputs as $item ({}; . *= $item)')

# Merge the manually recorded deployments on top, if there are any.
if [[ -f "$manual_file" ]]; then
  if ! jq empty "$manual_file" 2>/dev/null; then
    echo "Error: $manual_file is not valid JSON." >&2
    exit 1
  fi

  jq --slurp --sort-keys 'reduce .[] as $item ({}; . *= $item)' \
    <(printf '%s' "$generated") "$manual_file"
else
  printf '%s\n' "$generated"
fi
