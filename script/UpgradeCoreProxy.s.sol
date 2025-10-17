// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @notice Upgrades StakedMonad proxy to a new implementation
 * @dev StakedMonad implementation must have already been deployed
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Deploying address private key
 * @custom:example forge script UpgradeCoreProxy --sig "run(address)" $STAKED_MONAD_IMPL
 */
contract UpgradeCoreProxy is Script {
    function run(address newImplementation) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        console.log("Wallet: %s", vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);

        require(newImplementation.code.length > 0, "Invalid StakedMonad implementation");
        console.log("Using new StakedMonad implementation: %s", newImplementation);

        // Upgrade current proxy
        address currentProxyAddress = getDeploymentAddress("StakedMonad");
        UUPSUpgradeable currentProxy = UUPSUpgradeable(currentProxyAddress);
        console.log("Upgrading proxy found at: %s", currentProxyAddress);

        currentProxy.upgradeToAndCall(newImplementation, "");

        vm.stopBroadcast();

        // Update `abiSource` with new contract name for future versions
        upgradeArtifacts("StakedMonad", "StakedMonad");
    }

    function getDeploymentAddress(string memory contractName) internal view returns (address) {
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.readFile(path);
        return vm.parseJsonAddress(json, "$.address");
    }

    function upgradeArtifacts(string memory artifactName, string memory abiSource) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;

        string memory abiInput = string(abi.encodePacked("./out/", abiSource, ".sol/", abiSource, ".json"));
        string memory abiJson = vm.readFile(abiInput);
        string memory abiOutput = string(abi.encodePacked("./out/", artifactName, ".sol/", vm.toString(block.chainid), "_artifact.json"));
        vm.writeJson(abiJson, abiOutput);
    }
}
