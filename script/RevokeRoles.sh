# These should be run individually to confirm they execute

cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_ADD_NODE()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_UPDATE_WEIGHTS()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_DISABLE_NODE()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_REMOVE_NODE()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_FEE_SETTER()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_FEE_CLAIMER()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_FEE_EXEMPTION()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_UPGRADE()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "ROLE_PAUSE()(bytes32)") $MON_DEPLOYER
cast send $sMON --private-key $MON_DEPLOYER_PK "revokeRole(bytes32,address)" $(cast call $sMON "DEFAULT_ADMIN_ROLE()(bytes32)") $MON_DEPLOYER
