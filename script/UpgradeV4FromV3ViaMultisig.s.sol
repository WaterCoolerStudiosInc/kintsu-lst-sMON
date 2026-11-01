// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/StakedMonadV4.sol";

/**
 * @notice Deploys the StakedMonadV4 implementation and prints calldata used for a multisig proposal.
 * @dev The Safe executing the proposal must hold ROLE_UPGRADE and DEFAULT_ADMIN_ROLE; it receives ROLE_UNPAUSE, ROLE_FREEZE, ROLE_UNFREEZE and ROLE_SEIZE.
 * @dev The upgrade activates both the protocol pause and the transfer pause
 * @dev These environment variables are used:
 *     - PRIVATE_KEY:  Private key of the deploying account (only used when IMPL is not set)
 *     - IMPL:         Optional address of an already deployed StakedMonadV4 (default deploys a new one)
 *     - PROXY:        Optional proxy address override (default reads the recorded deployment for this chain)
 * @custom:example forge script UpgradeV4FromV3ViaMultisig --rpc-url monad_mainnet
 */
contract UpgradeV4FromV3ViaMultisig is Script {
    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev `initializeFromV3` requires the proxy to still be on V3
    uint64 private constant EXPECTED_INITIALIZED_VERSION = 3;

    function run() external virtual {
        address proxy = vm.envExists("PROXY") ? vm.envAddress("PROXY") : getV3DeploymentAddress("StakedMonad");

        checkInitializedVersion(proxy);

        address impl = vm.envOr("IMPL", address(0));
        if (impl == address(0)) {
            uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            console.log("Deploying StakedMonadV4 with deployer: %s", vm.addr(deployerPrivateKey));

            vm.startBroadcast(deployerPrivateKey);
            impl = address(new StakedMonadV4());
            vm.stopBroadcast();
        } else {
            require(impl.code.length > 0, "IMPL has no code");
            console.log("Using pre-deployed StakedMonadV4 implementation");
        }

        bytes memory initData = abi.encodeCall(StakedMonadV4.initializeFromV3, ());
        bytes memory calldata_ = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, initData));

        console.log("");
        console.log("StakedMonad Proxy: %s", proxy);
        console.log("StakedMonadV4 Implementation: %s", impl);
        console.log("StakedMonadV4.initializeFromV3() calldata:");
        console.logBytes(initData);
        console.log("");
        console.log("UUPSUpgradeable.upgradeToAndCall(...) calldata:");
        console.logBytes(calldata_);

        // Update `abiSource` with new contract name for future versions
        upgradeArtifacts("StakedMonad", "StakedMonadV4");
    }

    /// @dev Revert unless the proxy is still on V3, which `initializeFromV3` requires
    function checkInitializedVersion(address proxy) internal view {
        uint64 initializedVersion = uint64(uint256(vm.load(proxy, INITIALIZABLE_STORAGE)));
        if (initializedVersion != EXPECTED_INITIALIZED_VERSION) {
            console.log("Proxy initialized version: %s, expected: %s", initializedVersion, EXPECTED_INITIALIZED_VERSION);
            revert("Proxy is not on the expected version");
        }
    }

    function getV3DeploymentAddress(string memory contractName) private view returns (address) {
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
