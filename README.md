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
  forge script DeployCoreImpl --rpc-url anvil --broadcast
  forge script DeployCoreProxy --sig "run(address)" <IMPL_ADDRESS> --rpc-url anvil --broadcast
  ```
