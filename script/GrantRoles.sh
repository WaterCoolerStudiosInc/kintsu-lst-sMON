#!/usr/bin/env bash

recipient=$1

roles=(
  "ROLE_ADD_NODE"
  "ROLE_UPDATE_WEIGHTS"
  "ROLE_DISABLE_NODE"
  "ROLE_REMOVE_NODE"
  "ROLE_FEE_SETTER"
  "ROLE_FEE_CLAIMER"
  "ROLE_FEE_EXEMPTION"
  "ROLE_UPGRADE"
  "ROLE_PAUSE"
  "DEFAULT_ADMIN_ROLE"
)

for role in ${roles[@]}; do
  echo $role
  cast send $sMON --private-key $MON_DEPLOYER_PK "grantRole(bytes32,address)" $(cast call $sMON "$role()(bytes32)") $recipient
done
