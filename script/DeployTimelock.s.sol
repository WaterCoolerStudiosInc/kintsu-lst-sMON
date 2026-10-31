// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import "../src/StakedMonadV2.sol";

/**
 * @notice Deploys a TimelockController and transfers ROLE_UPGRADE on an existing
 *         StakedMonadV2 deployment from the caller to the timelock.
 * @notice After this script runs, future implementation upgrades must go through
 *         the timelock: schedule() -> wait for delay -> execute().
 *
 * @dev ROLE_UPGRADE is self-administered on StakedMonadV2, so the current holder
 *      both grants the role to the new timelock and renounces it in the same tx.
 *      Once renounced, only the timelock can grant or revoke ROLE_UPGRADE going
 *      forward, preserving the timelock guarantee.
 *
 * @dev Environment variables:
 *     - PRIVATE_KEY        - Private key of an account that currently holds ROLE_UPGRADE
 *     - TIMELOCK_DELAY     - Minimum delay in seconds (optional; default 72 hours)
 *     - TIMELOCK_PROPOSERS - Comma-separated proposer/canceller addresses (optional; default deployer)
 *     - TIMELOCK_EXECUTORS - Comma-separated executor addresses (optional; default 0x0 for open)
 *
 * @custom:example forge script DeployTimelock --broadcast --rpc-url $RPC_URL
 */
contract DeployTimelock is Script {
    uint256 public constant DEFAULT_DELAY = 72 hours;

    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        uint256 delay = vm.envOr("TIMELOCK_DELAY", DEFAULT_DELAY);
        address[] memory proposers = _envAddressArrayOr("TIMELOCK_PROPOSERS", deployer);
        address[] memory executors = _envAddressArrayOr("TIMELOCK_EXECUTORS", address(0));

        address proxy = getDeploymentAddress("StakedMonad");

        console.log("Deployer: %s", deployer);
        console.log("StakedMonad proxy: %s", proxy);
        console.log("Minimum delay (seconds): %s", delay);
        for (uint256 i; i < proposers.length; ++i) {
            console.log("Proposer/canceller: %s", proposers[i]);
        }
        for (uint256 i; i < executors.length; ++i) {
            console.log("Executor: %s", executors[i]);
        }

        vm.startBroadcast(deployerPrivateKey);
        address timelock = deployTimelockAndTransferRole(proxy, deployer, delay, proposers, executors);
        vm.stopBroadcast();

        console.log("TimelockController deployed at: %s", timelock);
        console.log("ROLE_UPGRADE transferred from %s to %s", deployer, timelock);

        writeTimelockArtifact(timelock);
    }

    /**
     * @notice Deploys a TimelockController and atomically transfers ROLE_UPGRADE to it.
     * @param proxy        - The StakedMonad(V2) proxy address
     * @param currentHolder - The account currently holding ROLE_UPGRADE (must equal the caller)
     * @param delay        - Minimum delay in seconds before a scheduled op can be executed
     * @param proposers    - Accounts granted PROPOSER_ROLE and CANCELLER_ROLE on the timelock
     * @param executors    - Accounts granted EXECUTOR_ROLE on the timelock (use address(0) for open)
     * @return timelock    - Address of the newly deployed TimelockController
     */
    function deployTimelockAndTransferRole(
        address proxy,
        address currentHolder,
        uint256 delay,
        address[] memory proposers,
        address[] memory executors
    ) public returns (address timelock) {
        // admin = address(0) so that even timelock configuration changes (delay, proposer
        // rotation, canceller rotation) must themselves be scheduled and executed through
        // the timelock. This preserves the time-delay guarantee for all privileged ops.
        timelock = address(new TimelockController(delay, proposers, executors, address(0)));

        StakedMonadV2 staked = StakedMonadV2(payable(proxy));
        bytes32 role = staked.ROLE_UPGRADE();

        // Caller must currently hold ROLE_UPGRADE for both of these to succeed.
        // ROLE_UPGRADE is self-administered, so the holder is authorized to grant it.
        staked.grantRole(role, timelock);
        // Renounce last: after this call, the caller can no longer undo the transfer.
        staked.renounceRole(role, currentHolder);
    }

    function getDeploymentAddress(string memory contractName) internal view returns (address) {
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.readFile(path);
        return vm.parseJsonAddress(json, "$.address");
    }

    function writeTimelockArtifact(address timelock) internal virtual {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;

        string memory deploymentJson = vm.serializeAddress("timelock_deployment.json", "address", timelock);
        string memory deploymentOutput = string(abi.encodePacked("./out/TimelockController.sol/", vm.toString(block.chainid), "_deployment.json"));
        vm.writeJson(deploymentJson, deploymentOutput);
    }

    function _envAddressArrayOr(string memory name, address fallbackValue) private view returns (address[] memory arr) {
        try vm.envAddress(name, ",") returns (address[] memory values) {
            arr = values;
        } catch {
            arr = new address[](1);
            arr[0] = fallbackValue;
        }
    }
}
