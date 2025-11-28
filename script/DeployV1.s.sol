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
contract DeployV1 is Script {
    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);
        (address proxy, address impl) = deployV1(deployer);
        vm.stopBroadcast();

        console.log("StakedMonad implementation deployed to: %s", impl);
        console.log("ERC1967Proxy (StakedMonad) deployed to: %s", proxy);

        writeArtifacts("StakedMonad", "StakedMonad", proxy);
    }

    function deployV1(address admin) public returns (address proxy, address impl) {
        // Deploy implementation
        impl = address(new StakedMonad());

        // Deploy and initialize proxy
        proxy = address(new ERC1967Proxy{value: 0.01 ether}(
            impl,
            abi.encodeCall(StakedMonad.initialize, (admin))
        ));
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
