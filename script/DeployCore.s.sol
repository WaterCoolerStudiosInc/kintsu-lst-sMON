// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/src/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry, StakedMonad} from "../src/StakedMonad.sol";

/**
 * Deploys the core contracts:
 *     - StakedMonad
 *     - ERC1967Proxy (StakedMonad Proxy)
 *
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Private key of the deploying account
 */
contract DeployCore is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy StakedMonad
        StakedMonad stakedMonad;
        {
            StakedMonad stakedMonadImpl = new StakedMonad();
            console.log("StakedMonad implementation deployed to: %s", address(stakedMonadImpl));

            // Deploy and configure ERC1967Proxy
            ERC1967Proxy stakedMonadProxy = new ERC1967Proxy(
                address(stakedMonadImpl),
                abi.encodeCall(StakedMonad.initialize, (deployer))
            );
            console.log("StakedMonad (ERC1967Proxy) deployed to: %s", address(stakedMonadProxy));

            // Associate StakedMonad ABI with proxy address
            stakedMonad = StakedMonad(payable(stakedMonadProxy));
        }

        vm.stopBroadcast();

        writeDeploymentAddress("StakedMonad", address(stakedMonad));
    }

    function writeDeploymentAddress(string memory contractName, address deployment) internal {
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.serializeAddress("deployment.json", "address", deployment);
        vm.writeJson(json, path);
    }
}
