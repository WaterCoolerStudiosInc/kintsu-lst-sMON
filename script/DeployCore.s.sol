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
contract DeployCore is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        StakedMonad stakedMonadImpl = new StakedMonad();
        console.log("StakedMonad implementation deployed to: %s", address(stakedMonadImpl));

        // Deploy and initialize proxy
        ERC1967Proxy stakedMonadProxy = new ERC1967Proxy{value: 0.01 ether}(
            address(stakedMonadImpl),
            abi.encodeCall(StakedMonad.initialize, (deployer))
        );
        console.log("ERC1967Proxy (StakedMonad) deployed to: %s", address(stakedMonadProxy));

        vm.stopBroadcast();

        writeDeploymentAddress("StakedMonad", address(stakedMonadProxy));
    }

    function writeDeploymentAddress(string memory contractName, address deployment) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.serializeAddress("deployment.json", "address", deployment);
        vm.writeJson(json, path);
    }
}
