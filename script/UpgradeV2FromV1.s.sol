// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/StakedMonadV2.sol";

/**
 * @notice Upgrades StakedMonad proxy from V1 to V2
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Deploying address private key
 * @custom:example forge script UpgradeCoreV2FromV1
 */
contract UpgradeV2FromV1 is Script {
    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        console.log("Wallet: %s", vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);
        address proxy = getDeploymentAddress("StakedMonad");
        (address impl) = upgradeV2FromV1(proxy);
        vm.stopBroadcast();

        console.log("StakedMonadV2 implementation deployed to: %s", impl);
        console.log("ERC1967Proxy (StakedMonadV2) upgraded at: %s", proxy);

        // Update `abiSource` with new contract name for future versions
        upgradeArtifacts("StakedMonad", "StakedMonadV2");
    }

    function upgradeV2FromV1(address proxy) public returns (address impl) {
        // Deploy new implementation
        impl = address(new StakedMonadV2());

        // Upgrade current proxy
        UUPSUpgradeable(proxy).upgradeToAndCall(
            impl,
            abi.encodeCall(StakedMonadV2.initializeFromV1, ())
        );
    }

    function getDeploymentAddress(string memory contractName) private view returns (address) {
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.readFile(path);
        return vm.parseJsonAddress(json, "$.address");
    }

    function upgradeArtifacts(string memory artifactName, string memory abiSource) private {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;

        string memory abiInput = string(abi.encodePacked("./out/", abiSource, ".sol/", abiSource, ".json"));
        string memory abiJson = vm.readFile(abiInput);
        string memory abiOutput = string(abi.encodePacked("./out/", artifactName, ".sol/", vm.toString(block.chainid), "_artifact.json"));
        vm.writeJson(abiJson, abiOutput);
    }
}
