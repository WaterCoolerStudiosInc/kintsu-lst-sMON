// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/StakedMonadV3.sol";

/**
 * @notice Deploys the StakedMonadV3 implementation and prints calldata used for a multisig proposal.
 * @dev These environment variables are used:
 *     - PRIVATE_KEY:    Private key of the deploying account (only used when IMPL is not set)
 *     - SYNC_NODE_IDS:  Optional comma separated node ids to re-sync with the precompile (default "17")
 *     - IMPL:           Optional address of an already deployed StakedMonadV3 (default deploys a new one)
 *     - PROXY:          Optional proxy address override (default reads the recorded deployment for this chain)
 * @custom:example SYNC_NODE_IDS="17" forge script UpgradeV3FromV2ViaMultisig --rpc-url monad_mainnet
 */
contract UpgradeV3FromV2ViaMultisig is Script {
    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev `initializeFromV2` requires the proxy to still be on V2
    uint64 private constant EXPECTED_INITIALIZED_VERSION = 2;

    function run() external virtual {
        address proxy = vm.envExists("PROXY") ? vm.envAddress("PROXY") : getV2DeploymentAddress("StakedMonad");
        uint64[] memory syncNodeIds = parseSyncNodeIds(vm.envOr("SYNC_NODE_IDS", string("17")));

        checkInitializedVersion(proxy);
        checkNodeIdsInRegistry(proxy, syncNodeIds);

        address impl = vm.envOr("IMPL", address(0));
        if (impl == address(0)) {
            uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            console.log("Deploying StakedMonadV3 with deployer: %s", vm.addr(deployerPrivateKey));

            vm.startBroadcast(deployerPrivateKey);
            impl = address(new StakedMonadV3());
            vm.stopBroadcast();
        } else {
            require(impl.code.length > 0, "IMPL has no code");
            console.log("Using pre-deployed StakedMonadV3 implementation");
        }

        bytes memory initData = abi.encodeCall(StakedMonadV3.initializeFromV2, (syncNodeIds));
        bytes memory calldata_ = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, initData));

        console.log("");
        console.log("StakedMonad Proxy: %s", proxy);
        console.log("StakedMonadV3 Implementation: %s", impl);
        console.log("Syncing %s node ids:", syncNodeIds.length);
        for (uint256 i; i < syncNodeIds.length; ++i) {
            console.log("  Node id: %s", syncNodeIds[i]);
        }
        console.log("StakedMonadV3.initializeFromV2(...) calldata:");
        console.logBytes(initData);
        console.log("");
        console.log("UUPSUpgradeable.upgradeToAndCall(...) calldata:");
        console.logBytes(calldata_);

        // Update `abiSource` with new contract name for future versions
        upgradeArtifacts("StakedMonad", "StakedMonadV3");
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

    function upgradeArtifacts(string memory artifactName, string memory abiSource) private {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;

        string memory abiInput = string(abi.encodePacked("./out/", abiSource, ".sol/", abiSource, ".json"));
        string memory abiJson = vm.readFile(abiInput);
        string memory abiOutput = string(abi.encodePacked("./out/", artifactName, ".sol/", vm.toString(block.chainid), "_artifact.json"));
        vm.writeJson(abiJson, abiOutput);
    }
}
