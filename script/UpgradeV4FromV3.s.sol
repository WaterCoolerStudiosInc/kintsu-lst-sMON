// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/StakedMonadV4.sol";

/**
 * @notice Upgrades StakedMonad proxy from V3 to V4
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Deploying address private key
 * @custom:example forge script UpgradeV4FromV3
 */
contract UpgradeV4FromV3 is Script {
    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        console.log("Wallet: %s", vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);
        address proxy = getV3DeploymentAddress("StakedMonad");
        (address impl) = upgradeV4FromV3(proxy);
        vm.stopBroadcast();

        console.log("StakedMonadV4 implementation deployed to: %s", impl);
        console.log("ERC1967Proxy (StakedMonadV4) upgraded at: %s", proxy);

        // Update `abiSource` with new contract name for future versions
        upgradeArtifactsToV4("StakedMonad", "StakedMonadV4");
    }

    function upgradeV4FromV3(address proxy) public returns (address impl) {
        // Deploy new implementation
        impl = address(new StakedMonadV4());

        // Upgrade current proxy
        UUPSUpgradeable(proxy).upgradeToAndCall(
            impl,
            abi.encodeCall(StakedMonadV4.initializeFromV3, ())
        );
    }

    function getV3DeploymentAddress(string memory contractName) private view returns (address) {
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.readFile(path);
        return vm.parseJsonAddress(json, "$.address");
    }

    function upgradeArtifactsToV4(string memory artifactName, string memory abiSource) private {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;

        string memory abiInput = string(abi.encodePacked("./out/", abiSource, ".sol/", abiSource, ".json"));
        string memory abiJson = vm.readFile(abiInput);
        string memory abiOutput = string(abi.encodePacked("./out/", artifactName, ".sol/", vm.toString(block.chainid), "_artifact.json"));
        vm.writeJson(abiJson, abiOutput);
    }
}
