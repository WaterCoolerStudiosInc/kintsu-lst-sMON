// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/StakedMonad.sol";

/**
 * @notice Transfers all initial roles from StakedMonad to a new address
 * @dev Sender must be the same address assigned these roles from `StakedMonad::initialize(admin)`
 * @custom:example forge script TransferRoles --sig "run(address)" $NEW_ADMIN
 */
contract TransferRoles is Script {
    function run(address newAdmin) external {
        uint256 senderPrivateKey = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(senderPrivateKey);
        console.log("Sender: %s", sender);
        console.log("New Admin: %s", newAdmin);

        address stakedMonadAddress = getDeploymentAddress("StakedMonad");

        StakedMonad stakedMonad = StakedMonad(payable(stakedMonadAddress));

        vm.startBroadcast(senderPrivateKey);

        // Registry roles (managed by DEFAULT_ADMIN_ROLE)
        {
            bytes32 ROLE_ADD_NODE = stakedMonad.ROLE_ADD_NODE();
            stakedMonad.grantRole(ROLE_ADD_NODE, newAdmin);
            stakedMonad.renounceRole(ROLE_ADD_NODE, sender);

            bytes32 ROLE_UPDATE_WEIGHTS = stakedMonad.ROLE_UPDATE_WEIGHTS();
            stakedMonad.grantRole(ROLE_UPDATE_WEIGHTS, newAdmin);
            stakedMonad.renounceRole(ROLE_UPDATE_WEIGHTS, sender);

            bytes32 ROLE_DISABLE_NODE = stakedMonad.ROLE_DISABLE_NODE();
            stakedMonad.grantRole(ROLE_DISABLE_NODE, newAdmin);
            stakedMonad.renounceRole(ROLE_DISABLE_NODE, sender);

            bytes32 ROLE_REMOVE_NODE = stakedMonad.ROLE_REMOVE_NODE();
            stakedMonad.grantRole(ROLE_REMOVE_NODE, newAdmin);
            stakedMonad.renounceRole(ROLE_REMOVE_NODE, sender);
        }

        // Fee roles (self-managed)
        {
            bytes32 ROLE_FEE_SETTER = stakedMonad.ROLE_FEE_SETTER();
            stakedMonad.grantRole(ROLE_FEE_SETTER, newAdmin);
            stakedMonad.renounceRole(ROLE_FEE_SETTER, sender);

            bytes32 ROLE_FEE_CLAIMER = stakedMonad.ROLE_FEE_CLAIMER();
            stakedMonad.grantRole(ROLE_FEE_CLAIMER, newAdmin);
            stakedMonad.renounceRole(ROLE_FEE_CLAIMER, sender);

            bytes32 ROLE_FEE_EXEMPTION = stakedMonad.ROLE_FEE_EXEMPTION();
            stakedMonad.grantRole(ROLE_FEE_EXEMPTION, newAdmin);
            stakedMonad.renounceRole(ROLE_FEE_EXEMPTION, sender);
        }

        // Upgrade roles (self-managed)
        {
            bytes32 ROLE_UPGRADE = stakedMonad.ROLE_UPGRADE();
            stakedMonad.grantRole(ROLE_UPGRADE, newAdmin);
            stakedMonad.renounceRole(ROLE_UPGRADE, sender);
        }

        // Other roles (managed by DEFAULT_ADMIN_ROLE)
        {
            bytes32 ROLE_PAUSE = stakedMonad.ROLE_PAUSE();
            stakedMonad.grantRole(ROLE_PAUSE, newAdmin);
            stakedMonad.renounceRole(ROLE_PAUSE, sender);

            bytes32 ROLE_TOGGLE_INSTANT_UNLOCK = stakedMonad.ROLE_TOGGLE_INSTANT_UNLOCK();
            stakedMonad.grantRole(ROLE_TOGGLE_INSTANT_UNLOCK, newAdmin);
            stakedMonad.renounceRole(ROLE_TOGGLE_INSTANT_UNLOCK, sender);
        }

        // Default admin role
        {
            bytes32 DEFAULT_ADMIN_ROLE = stakedMonad.DEFAULT_ADMIN_ROLE();
            stakedMonad.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
            stakedMonad.renounceRole(DEFAULT_ADMIN_ROLE, sender);
        }

        vm.stopBroadcast();
    }

    function getDeploymentAddress(string memory contractName) internal view returns (address) {
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.readFile(path);
        address _address = vm.parseJsonAddress(json, "$.address");
        if (_address.code.length == 0) revert("Deployment does not exist!");
        return _address;
    }
}
