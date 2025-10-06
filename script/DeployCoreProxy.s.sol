// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/src/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakedMonad.sol";

/**
 * @notice Deploys and configures an ERC1967Proxy for StakedMonad
 * @dev StakedMonad implementation must have already been deployed
 * @dev Gas estimation is currently drastically underestimated for Monad-tn2 so we must override this (5x)
 * @dev These environment variables must be set:
 *      - PRIVATE_KEY - Private key of the deploying account
 * @custom:example forge script DeployCoreProxy --sig "run(address)" $STAKED_MONAD_IMPL --gas-estimate-multiplier 500
 */
contract DeployCoreProxy is Script {
    function run(address stakedMonadImpl) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: %s", deployer);

        // Utilize already deployed implementation
        require(stakedMonadImpl.code.length > 0, "Invalid StakedMonad implementation");
        console.log("StakedMonad implementation already deployed at: %s", address(stakedMonadImpl));

        vm.startBroadcast(deployerPrivateKey);

        // Deploy and initialize proxy
        ERC1967Proxy stakedMonadProxy = new ERC1967Proxy{value: 0.01 ether}(
            stakedMonadImpl,
            abi.encodeCall(StakedMonad.initialize, (deployer))
        );
        console.log("ERC1967Proxy (StakedMonad) deployed to: %s", address(stakedMonadProxy));

        vm.stopBroadcast();

        writeDeploymentAddress("StakedMonad", address(stakedMonadProxy));
    }

    function writeDeploymentAddress(string memory contractName, address deployment) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        string memory path = string(abi.encodePacked("./out/", contractName, ".sol/", vm.toString(block.chainid), "_", "deployment.json"));
        string memory json = vm.serializeAddress("deployment.json", "address", deployment);
        vm.writeJson(json, path);
    }
}
