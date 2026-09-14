// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/StakedMonadV3.sol";

/**
 * @notice Upgrades StakedMonad proxy from V2 to V3
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Deploying address private key
 *     - SYNC_NODE_IDS - Comma separated node ids to re-sync with the precompile (default "17", use "" for none)
 * @dev Every node id given must exist in the Registry
 * @custom:example SYNC_NODE_IDS="" forge script UpgradeV3FromV2
 */
contract UpgradeV3FromV2 is Script {
    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint64[] memory syncNodeIds = parseSyncNodeIds(vm.envOr("SYNC_NODE_IDS", string("17")));
        console.log("Wallet: %s", vm.addr(deployerPrivateKey));
        console.log("Syncing %s node id(s)", syncNodeIds.length);
        for (uint256 i; i < syncNodeIds.length; ++i) {
            console.log("  Node id: %s", syncNodeIds[i]);
        }

        vm.startBroadcast(deployerPrivateKey);
        address proxy = getV2DeploymentAddress("StakedMonad");
        (address impl) = upgradeV3FromV2(proxy, syncNodeIds);
        vm.stopBroadcast();

        console.log("StakedMonadV3 implementation deployed to: %s", impl);
        console.log("ERC1967Proxy (StakedMonadV3) upgraded at: %s", proxy);

        // Update `abiSource` with new contract name for future versions
        upgradeArtifactsToV3("StakedMonad", "StakedMonadV3");
    }

    function upgradeV3FromV2(address proxy, uint64[] memory syncNodeIds) public returns (address impl) {
        // Deploy new implementation
        impl = address(new StakedMonadV3());

        // Upgrade current proxy
        UUPSUpgradeable(proxy).upgradeToAndCall(
            impl,
            abi.encodeCall(StakedMonadV3.initializeFromV2, (syncNodeIds))
        );
    }

    /// @dev Parse comma separated string of node ids
    /// @dev An empty string yields an empty array
    function parseSyncNodeIds(string memory csv) internal pure returns (uint64[] memory ids) {
        if (bytes(csv).length == 0) return ids;
        string[] memory parts = vm.split(csv, ",");
        ids = new uint64[](parts.length);
        for (uint256 i; i < parts.length; ++i) {
            ids[i] = uint64(vm.parseUint(parts[i]));
        }
    }

    function getV2DeploymentAddress(string memory contractName) private view returns (address) {
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.readFile(path);
        return vm.parseJsonAddress(json, "$.address");
    }

    function upgradeArtifactsToV3(string memory artifactName, string memory abiSource) private {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;

        string memory abiInput = string(abi.encodePacked("./out/", abiSource, ".sol/", abiSource, ".json"));
        string memory abiJson = vm.readFile(abiInput);
        string memory abiOutput = string(abi.encodePacked("./out/", artifactName, ".sol/", vm.toString(block.chainid), "_artifact.json"));
        vm.writeJson(abiJson, abiOutput);
    }
}
