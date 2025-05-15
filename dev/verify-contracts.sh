#!/bin/bash

set -o errexit -o nounset -o pipefail

chain_id=${1-}
custom_verifier_endpoint=${2-}

repo_root_dir="$(git rev-parse --show-toplevel)"
networks_json="$repo_root_dir/networks.json"
standard_json_input_dir="$repo_root_dir/broadcast/StandardJsonInput"

if ! [[ "$chain_id" =~ [0-9]+ ]]; then
  echo "Usage:"
  echo "  \$ export ETHERSCAN_API_KEY='<your Etherscan key here>'"
  echo "  \$ $0 <chain-id>"
  echo "For example, on Arbitrum:"
  echo "  \$ $0 43114"
  echo "You can optionally specify a custom API endpoint for the explorer:"
  echo "  \$ $0 <chain-id> <API endpoint>"
  echo "For example, on Avalanche:"
  echo "  \$ $0 43114 'https://api.snowscan.xyz/api'"
  exit 1
fi

if ! which jq > /dev/null; then
  echo "This script requires jq to be installed"
  exit 1
fi

address_by_contract_name() {
  local name=$1
  printf "%s" "$(jq --raw-output ".${name}[\"$chain_id\"].address" "$networks_json")"
}

forge_verify() {
  local address=$1
  local contract=$2

  if [ -n "$custom_verifier_endpoint" ]; then
    forge verify-contract --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" --chain-id "$chain_id" --verifier-url "$custom_verifier_endpoint" "$address" "$contract"
  else
    forge verify-contract --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" --chain-id "$chain_id" "$address" "$contract" 
  fi

  # Note: because of https://github.com/cowprotocol/composable-cow/issues/93, we
  # can only do partial verification on Sourcify because the contract metatata
  # don't match.
  # However, if the contract is already (partially) verified on Sourcify and we
  # run the following line, the command fails and the script stops (status code
  # 409 Conflict). If the verifier is Etherscan instead, then the script
  # tells us that the contract is already verified and makes the script pass.
  # We want to ignore this failure (with `|| true`) to make it possible to rerun
  # the script if updated with new contracts.
  forge verify-contract --verifier sourcify --chain-id "$chain_id" "$address" "$contract" || true

  contract_name=${contract##*:}
  forge verify-contract --show-standard-json-input "$address" "$contract" > "$standard_json_input_dir/$contract_name.json"
}



for path in \
  "lib/safe/contracts/handler/ExtensibleFallbackHandler.sol" \
  "src/ComposableCoW.sol" \
  "src/types/twap/TWAP.sol" \
  "src/types/GoodAfterTime.sol" \
  "src/types/PerpetualStableSwap.sol" \
  "src/types/TradeAboveThreshold.sol" \
  "src/types/StopLoss.sol" \
  "src/value_factories/CurrentBlockTimestampFactory.sol" \
; do
  filename="${path##*/}"
  contract="${filename%%.sol}"
  address="$(address_by_contract_name "$contract")"
  echo "Verifying contract $contract..."
  forge_verify "$address" "$path:$contract"
done

echo "All done!"
