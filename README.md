# 🏦 InterShare Protocol

**InterShare (IS21)** is a decentralized financial infrastructure that
bridges **real-world fiat reserves** with **on-chain financial
primitives** such as swaps, staking, and lending.

The protocol is built around a **fiat-backed reserve currency (IS21)**
and a modular architecture of gateway contracts that enforce strict
accounting between **on-chain supply and off-chain reserves**.

InterShare is designed to provide:

-   Transparent reserve accounting
-   Secure minting and redemption flows
-   Fiat-backed stability
-   Modular DeFi integrations

------------------------------------------------------------------------

# 🧠 Protocol Architecture

The InterShare protocol separates responsibilities into specialized
smart contracts.

### Core Principles

-   **Exogenous collateralization** -- IS21 is backed by verified
    off-chain fiat reserves.
-   **Strict supply control** -- minting and burning must match reserve
    changes.
-   **Gateway architecture** -- external integrations cannot mint
    directly - only an approved gateway/wallet address.
-   **Auditable reserve proofs** -- auditors publish off-chain reserve
    verification.

------------------------------------------------------------------------

# 🪙 IS21 Token (IS21Engine)

`IS21Engine` implements the **InterShare21 reserve currency**.

IS21 is a fiat-backed ERC‑20 token whose supply is controlled by the
protocol's **Fund Manager Gateway**.

### Key Features

-   ERC20 token (18 decimals)
-   ERC20Permit support
-   Fiat reserve tracking across multiple currencies
-   Role-based authorization
-   Reserve proof verification
-   Minting and burning tied to reserve changes
-   Pausable emergency controls
-   Reentrancy protection

### Roles

  Role                   Responsibilities
  ---------------------- -----------------------------------------------
  Owner                  manages protocol roles and emergency controls
  Fund Manager Gateway   only contract allowed to mint/burn IS21
  Auditors               verify reserves and publish proof hashes

------------------------------------------------------------------------

# 🏛 Fund Manager Gateway

`IS21FundManagerGateway` is the **single authorized fund manager** of
the IS21 token.

It acts as the **accounting layer** between reserve updates and token
supply.

### Responsibilities

-   Mint IS21 when reserves increase
-   Burn IS21 when reserves decrease
-   Synchronize fiat reserves
-   Authorize protocol contracts to mint/burn

### Atomic Accounting

Reserve changes and mint/burn operations occur **within the same
transaction** to guarantee consistency.

Example flow:

Reserve Increase → Mint IS21\
Reserve Decrease → Burn IS21

------------------------------------------------------------------------

# 🔁 USDT Swapping Gateway

`IS21USDTSwappingGateway` handles **user-facing swaps between USDT and
IS21**.

Swaps require **signed quotes** issued by a trusted signer.

### Mint Flow (USDT → IS21)

1.  User receives a signed quote\
2.  User sends USDT\
3.  Gateway increases reserves\
4.  FundManagerGateway mints IS21

### Burn Flow (IS21 → USDT)

1.  User submits signed quote\
2.  IS21 is burned\
3.  Reserves decrease\
4.  USDT is transferred to the user

### Security Features

-   EIP‑712 signed quotes
-   Replay protection via nonces
-   Expiry protection
-   Liquidity tracking
-   Pausable gateway

------------------------------------------------------------------------

# 🪙 Yield Vault

`IS21RewardVault` will allow users to **stake IS21 and earn IS21
rewards**.

The vault is based on the **ERC4626 tokenized vault standard**.

### Features

-   Push-based reward distribution
-   Streaming rewards
-   Loyalty multiplier tiers
-   No lockups
-   Flash‑loan protection

------------------------------------------------------------------------

# 💰 InterShare Lending (Under Development)

`ISLoanEngine` will power **InterShare Lending**, a decentralized
lending protocol inspired by systems like Aave.

### Planned Features

-   Multi‑asset collateral deposits
-   Borrowing against collateral
-   Interest accrual via supply/borrow indexes
-   Health factor monitoring
-   Liquidation mechanisms
-   Oracle price feeds

------------------------------------------------------------------------

# 📂 Repository Structure

```
├── src/                    # Solidity source code
│
│   ├── gateways/           # Gateways to interact with the main contracts
│   │   ├── IS21FundManagerGateway.sol
│   │   └── IS21USDTSwappingGateway.sol
│   │
│   ├── vaults/             # IS21 staking vault
│   │   └── IS21RewardVault.sol
│   │
│   ├── libraries/          # Libraries
│   │  
│   │   
│   │
│   ├── types/              # Types
│   │   
│   │
│   ├── mocks/              # Any mock contracts
│   │   └── MockUSDT.sol
│   │
│   ├── config/             # Any config
│   │   
│   │
│   └── IS21Engine.sol      # The main IS21 ERC-20 contract
│
├── script/                 # Solidity deployment scripts
│   ├── DeployIS21Engine.s.sol
│   ├── DeployIS21FundManagerGateway.s.sol
│   ├── DeployIS21USDTSwappingGateway.s.sol
│   ├── DeployIS21YieldVault.s.sol
│   └── DeployMockUSDT.s.sol
│
├── scripts/                # Bash deployment scripts (calls the solidity deployment scripts)
│   ├── _deploy.sh
│   ├── deploy_is21_engine.sh
│   ├── deploy_is21_fund_manager_gateway.sh
│   ├── deploy_is21_usdt_swapping_gateway.sh
│   ├── deploy_is21_yield_vault.sh
│   └── deploy_mock_usdt.sh
│
├── test/                   # Tests for unit, fuzz and mock testing
│   ├── unit/
│   ├── fuzz/
│   └── mock/
│
├── lib/                    # External dependencies (ignored by git)
├── foundry.toml            # Foundry config
└── README.md               # This README file
```

------------------------------------------------------------------------

# ⚙️ Development

### Install Foundry

```
curl -L https://foundry.paradigm.xyz \| bash\
foundryup
```

------------------------------------------------------------------------

# 📦 Install Dependencies

Install dependencies

```
forge install
```

------------------------------------------------------------------------

# 🚀 Deployments

Deployment scripts are located in the `scripts/` directory.

### Local Deployment (Anvil)

```
./scripts/deploy_is21_engine.sh anvil
./scripts/deploy_is21_fund_manager_gateway.sh anvil
./scripts/deploy_is21_usdt_swapping_gateway.sh anvil
```
etc.

### Sepolia Deployment

```
./scripts/deploy_is21_engine.sh sepolia
./scripts/deploy_is21_fund_manager_gateway.sh sepolia
./scripts/deploy_is21_usdt_swapping_gateway.sh sepolia
```
etc.

### Mock USDT (testing only)

./scripts/deploy_mock_usdt.sh anvil

------------------------------------------------------------------------

# 🧪 Testing

Run all tests:

```
forge test -vv
```

Run a specific test:

```
forge test --match-path test/unit/`<TestName>`{=html}.t.sol -vvv
```

Run fuzz tests:

```
forge test --match-path test/fuzz -vvvv
```

------------------------------------------------------------------------

# 📊 Coverage

Check testing coverage of contracts

```
forge coverage
```

------------------------------------------------------------------------

# 🔒 Security

The protocol incorporates several security mechanisms:

-   Role-based authorization
-   Reentrancy protection
-   Pausable emergency controls
-   Signed swap quotes
-   Nonce-based replay protection
-   Atomic reserve accounting

------------------------------------------------------------------------

# 📜 License

MIT License

© 2025 InterShare
