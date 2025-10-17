// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakedMonad.sol";

/**
 * @notice Deploys the contract implementation of StakedMonad
 * @dev These environment variables must be set:
 *     - PRIVATE_KEY - Private key of the deploying account
 */
contract DeployCore is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        StakedMonad stakedMonadImpl = new StakedMonad();
        console.log("StakedMonad implementation deployed to: %s", address(stakedMonadImpl));

        // Deploy and initialize proxy
        ERC1967Proxy stakedMonadProxy = new ERC1967Proxy{value: 0.01 ether}(
            address(stakedMonadImpl),
            abi.encodeCall(StakedMonad.initialize, (deployer))
        );
        console.log("ERC1967Proxy (StakedMonad) deployed to: %s", address(stakedMonadProxy));

        vm.stopBroadcast();

        writeArtifacts("StakedMonad", "StakedMonad", address(stakedMonadProxy));
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
