// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/Splitter.sol";

/**
 * @notice Deploys the SplitterFactory
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Private key of the deploying account
 */
contract DeploySplitterFactory is Script {
    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);
        address splitterFactory = deployFactory();
        address splitter = SplitterFactory(splitterFactory).create(deployer);
        vm.stopBroadcast();

        console.log("SplitterFactory deployed to: %s", splitterFactory);
        console.log("Splitter deployed to: %s", splitter);

        writeArtifacts("SplitterFactory", "SplitterFactory", splitterFactory);
    }

    function deployFactory() public returns (address factory) {
        // Deploy SplitterFactory
        factory = address(new SplitterFactory());
    }

    function writeArtifacts(string memory artifactName, string memory abiSource, address deployment) internal virtual {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;

        string memory abiInput = string(abi.encodePacked("./out/", abiSource, ".sol/", abiSource, ".json"));
        string memory abiJson = vm.readFile(abiInput);
        string memory abiOutput = string(abi.encodePacked("./out/", artifactName, ".sol/", vm.toString(block.chainid), "_artifact.json"));
        vm.writeJson(abiJson, abiOutput);

        string memory deploymentJson = vm.serializeAddress("deployment.json", "address", deployment);
        string memory deploymentOutput = string(abi.encodePacked("./out/", artifactName, ".sol/", vm.toString(block.chainid), "_deployment.json"));
        vm.writeJson(deploymentJson, deploymentOutput);
    }
}
