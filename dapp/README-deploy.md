# Base deployment

Router: 0x000000000000FB114709235f1ccBFfb925F600e4 (deployed, verified)
Quoter: 0x000000fF982A225Bc7472Ad36759F6Fff0BC5455 (mined, free)

Serve the dapp — wallets do not inject over file://:

    cd dapp && python3 -m http.server 8017
    open http://localhost:8017/deploy-base.html

Verify the quoter bytecode before signing:

    forge build --contracts src/zQuoterBase.sol --skip 'test/**'
    # keccak of .bytecode.object from out/zQuoterBase.sol/zQuoterBase.json
    # must equal 0xf4cc7c306c7b77d2267a35eb16ea7a7a3e880f29f3150276342bebc7892219a2

Verify on Basescan after deploying. zQuoterBase is pinned to 200 optimizer runs
in foundry.toml, and forge verify-contract ignores compilation_restrictions, so
the flag must be passed explicitly:

    forge verify-contract 0x000000fF982A225Bc7472Ad36759F6Fff0BC5455 \
      src/zQuoterBase.sol:zQuoterBase --chain 8453 \
      --etherscan-api-key <key> --compiler-version 0.8.36 \
      --num-of-optimizations 200 --via-ir --watch

Run the fork tests throttled, or the provider drops the connection mid-suite:

    BASE_RPC_URL=<rpc> forge test --match-path test/zBase.t.sol \
      --fork-url <rpc> --threads 1 --fork-retries 20 \
      --fork-retry-backoff 3000 --compute-units-per-second 100
