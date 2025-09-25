// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakedMonad.sol";

/**
 * @notice Deploys the contract implementation of StakedMonad
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Private key of the deploying account
 */
contract DeployCoreImpl is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        StakedMonad stakedMonadImpl = new StakedMonad();
        console.log("StakedMonad implementation deployed to: %s", address(stakedMonadImpl));

        vm.stopBroadcast();
    }
}
