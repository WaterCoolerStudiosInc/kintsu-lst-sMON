// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/src/Script.sol";
import {KintsuBetaERC1155} from "../src/token-gate/KintsuBetaERC1155.sol";

/**
 * Deploys the beta NFT:
 *     - KintsuBetaERC1155
 *
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Private key of the deploying account
 */
contract DeployBetaNft is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy KintsuBetaERC1155
        KintsuBetaERC1155 kintsuBetaERC1155 = new KintsuBetaERC1155("https://kintsu.xyz/api/beta-pass-metadata");
        console.log("KintsuBetaERC1155 deployed to: %s", address(kintsuBetaERC1155));

        vm.stopBroadcast();

        writeDeploymentAddress("KintsuBetaERC1155", address(kintsuBetaERC1155));
    }

    function writeDeploymentAddress(string memory contractName, address deployment) internal {
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.serializeAddress("deployment.json", "address", deployment);
        vm.writeJson(json, path);
    }
}
