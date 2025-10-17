// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "../src/token-gate/KintsuBetaERC1155.sol";

/**
 * @notice Deploys the beta NFT KintsuBetaERC1155
 * @dev These environment variables must be set:
 *      - PRIVATE_KEY - Private key of the deploying account
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

        writeArtifacts("KintsuBetaERC1155", "KintsuBetaERC1155", address(kintsuBetaERC1155));
    }

    function writeArtifacts(string memory artifactName, string memory abiSource, address deployment) internal {
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
