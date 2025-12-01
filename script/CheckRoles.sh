#!/usr/bin/env bash

holder=$1

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
  cast call $sMON "hasRole(bytes32,address)(bool)" $(cast call $sMON "$role()(bytes32)") $holder
done
