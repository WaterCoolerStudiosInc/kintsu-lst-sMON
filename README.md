# Monad Contracts

### Install Build Tools

```shell
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge soldeer install
```

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Deploy contracts locally

- Open new terminal and run
  ```shell
  anvil --code-size-limit 128000
  ```
- Create `.env` file (if not already present) from [.env.local](.env.local) template
- Change `.env` file if desired, currently configured with default anvil wallet
- Deploy in separate terminal window with:
  ```shell
  forge script DeployCore --rpc-url anvil --broadcast
  ```

### Common commands
```bash
cast call $SMON "balanceOf(address)(uint256)" $ME
cast call $SMON "getAllUserUnlockRequests(address)((uint96,uint96,uint40,uint16)[])" $ME
cast send $SMON --private-key $PK "deposit(uint96,address)(uint96)" 0 $ME --value "1 ether"
cast send $SMON --private-key $PK "requestUnlock(uint96,uint96)(uint96)" "1 ether" 0
cast send $SMON --private-key $PK "redeem(uint256,address)(uint96)" 0 $ME
cast send $SMON --private-key $PK "submitBatch()"
cast send $SMON --private-key $PK "sweep(uint64[],uint8)" "[3]" 32
cast send $SMON --private-key $PK "compound(uint64[])" "[3]"
```

### Direct Staking Precompile Interactions
```bash
cast call 0x0000000000000000000000000000000000001000 "getDelegator(uint64,address)(uint256,uint256,uint256,uint256,uint256,uint256,uint256)" 3 $ME
cast send --private-key $PK 0x0000000000000000000000000000000000001000 "delegate(uint64)(bool)" 3 --value "0.1 ether"
cast send --private-key $PK 0x0000000000000000000000000000000000001000 "undelegate(uint64,uint256,uint8)(bool)" 3 "0.1 ether" 0
cast send --private-key $PK 0x0000000000000000000000000000000000001000 "withdraw(uint64,uint8)(bool)" 3 0
```
