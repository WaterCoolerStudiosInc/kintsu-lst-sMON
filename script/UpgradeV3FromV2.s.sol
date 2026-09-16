// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/StakedMonadV3.sol";

/**
 * @notice Upgrades StakedMonad proxy from V2 to V3
 * @dev These environment variables are used:
 *     - PRIVATE_KEY:    Private key of the deploying account
 *     - SYNC_NODE_IDS:  Comma separated node ids to re-sync with the precompile (default "17")
 *     - PROXY:          Optional proxy address override (default reads the recorded deployment for this chain)
 * @custom:example SYNC_NODE_IDS="17" forge script UpgradeV3FromV2 --rpc-url monad_mainnet
 */
contract UpgradeV3FromV2 is Script {
    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev `initializeFromV2` requires the proxy to still be on V2
    uint64 private constant EXPECTED_INITIALIZED_VERSION = 2;

    function run() external virtual {
        address proxy = vm.envExists("PROXY") ? vm.envAddress("PROXY") : getV2DeploymentAddress("StakedMonad");
        uint64[] memory syncNodeIds = parseSyncNodeIds(vm.envOr("SYNC_NODE_IDS", string("17")));

        checkInitializedVersion(proxy);
        checkNodeIdsInRegistry(proxy, syncNodeIds);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        console.log("Wallet: %s", vm.addr(deployerPrivateKey));
        console.log("Syncing %s node id(s)", syncNodeIds.length);
        for (uint256 i; i < syncNodeIds.length; ++i) {
            console.log("  Node id: %s", syncNodeIds[i]);
        }

        vm.startBroadcast(deployerPrivateKey);
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

    /// @dev Revert unless the proxy is still on V2, which `initializeFromV2` requires
    function checkInitializedVersion(address proxy) internal view {
        uint64 initializedVersion = uint64(uint256(vm.load(proxy, INITIALIZABLE_STORAGE)));
        if (initializedVersion != EXPECTED_INITIALIZED_VERSION) {
            console.log("Proxy initialized version: %s, expected: %s", initializedVersion, EXPECTED_INITIALIZED_VERSION);
            revert("Proxy is not on the expected version");
        }
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

    /// @dev Revert if any node id does not exist in the Registry
    function checkNodeIdsInRegistry(address proxy, uint64[] memory syncNodeIds) internal view {
        if (syncNodeIds.length == 0) return;

        uint256[] memory registeredNodeIds = StakedMonadV3(payable(proxy)).getNodeIds();
        for (uint256 i; i < syncNodeIds.length; ++i) {
            bool found;
            for (uint256 j; j < registeredNodeIds.length; ++j) {
                if (registeredNodeIds[j] == syncNodeIds[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                console.log("Node id not in the Registry: %s", syncNodeIds[i]);
                revert("Node id not in the Registry");
            }
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
