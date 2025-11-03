# 🏦 InterShare Protocol

**InterShare (IS21)** is a decentralized financial system that bridges **real-world fiat reserves** with **on-chain liquidity and lending**.  
It consists of two core smart contracts — **IS21Engine** (the fiat-backed reserve token - IS21) and **ISLoanEngine** (the lending and borrowing platform).  
Together, they create a transparent, collateralized, and risk-managed ecosystem for the next generation of decentralized finance.

---

## ⚙️ Core Components

### 💰 ISLoanEngine
The **InterShare Lending Protocol**, enabling decentralized lending, borrowing, and automated interest accrual.  
It tracks health factors, manages liquidations, and ensures solvency through oracle-based asset pricing.

**Key Features:**
- **Collateralized Lending:** deposit assets and borrow against supported collateral
- **Dynamic Health Factor:** real-time collateral vs. debt risk tracking
- **Interest Accrual:** continuous per-second compounding with supply and borrow indices
- **Hybrid Oracle Integration:** Chainlink + Pyth dual-source oracle with fallback
- **Liquidations:** third-party participants maintain solvency and earn bonuses
- **Role-Based Governance:** Owner / Fund Manager separation
- **Pausing & Reentrancy Protection:** all external calls guarded
- **Comprehensive Test Suite:** 20+ passing unit tests covering all flows

---

### 🪙 IS21Engine
A decentralized **reserve currency** that is **exogenously collateralized and fiat-backed**.  
It provides transparent proof-of-reserve tracking, role-based minting, and auditable fiat management.

**Key Features:**
- ERC20 standard with:
  - [`ERC20Burnable`](https://docs.openzeppelin.com/contracts/4.x/api/token/erc20#ERC20Burnable)
  - [`ERC20Permit`](https://docs.openzeppelin.com/contracts/4.x/api/token/erc20#ERC20Permit)
- Role-based access:
  - **Owner** – manages roles, pausing, and rescue operations
  - **Fund Managers** – authorized to mint and burn tokens
  - **Auditors** – verify fiat reserves and proof hashes
- Fiat reserves tracking with hash-based verification
- Pausable for emergency halts
- Rescue function for mistakenly sent ERC20s
- Comprehensive **unit and fuzz testing** with Foundry

---

## 📂 Project Structure

```
├── src/
│   ├── IS21Engine.sol          # Reserve currency contract
│   ├── ISLoanEngine.sol        # Lending protocol contract
│   └── libraries/
│       └── OracleLib.sol       # Chainlink + Pyth oracle integration
│
├── script/
│   ├── DeployIS21Engine.s.sol   # Deployment script for the IS21 ERC-20 contract.
│   └── DeployISLoanEngine.s.sol # Deployment script for the InterShare lending protocol contract.
│
├── test/
│   ├── unit/                   # Unit tests for IS21Engine & ISLoanEngine
│   └── fuzz/                   # Fuzz tests for stress and edge cases for IS21Engine & ISLoanEngine
│   └── mocks/                  # Mock files for Oracle tests
│
└── foundry.toml                # Foundry configuration
```

---

## ⚡ Getting Started

### Prerequisites
- [Foundry](https://getfoundry.sh/) (includes Anvil, Forge, Cast)

Install Foundry:
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install Dependencies
```bash
forge install
```

---

## 🚀 Deployments

### Deployment (IS21Engine)

Deploy locally with Anvil:
```bash
./deploy_is21.sh anvil
```

Deploy to Sepolia testnet:
```bash
./deploy_is21.sh sepolia
```

---

### Deployment (ISLoanEngine)

Deploy locally with Anvil:
```bash
./deploy_is_loan_engine.sh anvil
```

Deploy to Sepolia testnet:
```bash
./deploy_is_loan_engine.sh sepolia
```

---

## 🧪 Testing

Run all tests:
```bash
forge test -v
```

Run specific test:
```bash
forge test --match-path test/unit/ISLoanEngineTest.t.sol -vvv
```

Run fuzz tests with higher iterations:
```bash
forge test --match-path test/fuzz/IS21EngineFuzz.t.sol -vvvv --fuzz-runs 500
```

View detailed traces:
```bash
forge test -vvvvv
```

---

## 📊 Coverage

Generate coverage report:
```bash
forge coverage
```

Generate coverage report with minimum optimization:
```bash
forge coverage --ir-minimum
```

Exclude deployment scripts (configured in `foundry.toml`):
```toml
[coverage]
no_match_coverage = "/.*(?i)Deploy.*.s.sol"
```

---

## 🔒 Security & Audit Readiness

- ✅ Role-based access control (Owner / FundManager / Auditor)
- ✅ Reentrancy protection (`nonReentrant`)
- ✅ Emergency pause mechanisms (`Pausable`)
- ✅ Oracle freshness verification with dual-source fallback

---

## 📜 License

**MIT License**  
© 2025 **InterShare**

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software.
