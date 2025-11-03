# 🏦 InterShare Protocol

**InterShare (IS21)** is a decentralized financial system that bridges **real-world fiat reserves** with **on-chain liquidity and lending**.  
It consists of two core smart contracts — **IS21Engine** (the fiat-backed reserve token - IS21) and **ISLoanEngine** (the lending and borrowing platform).  
Together, they create a transparent, collateralized, and risk-managed ecosystem for the next generation of decentralized finance.

---

## 🔗 Smart Contracts Overview

The InterShare ecosystem is powered by two foundational smart contracts — **IS21Engine** and **ISLoanEngine** — designed for transparency, collateralization, and real-world integration.

### 🪙 IS21Engine

Implements the **InterShare21 (IS21)** token — a decentralized, exogenously collateralized reserve currency backed by verified fiat reserves.  
It provides on-chain accountability and controlled minting/burning through strict role-based permissions.

**Highlights:**

- ERC20 standard with:
  - [`ERC20Burnable`](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#ERC20Burnable)
  - [`ERC20Permit`](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#ERC20Permit)
- Role-based access:
  - **Owner** – manages roles, pausing, and rescue operations
  - **Fund Managers** – authorized to mint and burn tokens
  - **Auditors** – verify fiat reserves and proof hashes
- **Fiat-Backed Reserves:** tracks USD, EUR, ZAR, and other supported currencies
- **Proof-of-Audit:** stores off-chain audit hashes for transparency
- **Minting & Redemption:** secure issuance and burning tied to reserve changes
- **Pausable & Reentrancy-Protected:** compliant with industry-grade safety patterns
- **Version:** `IS21_VERSION = "1.0.0"`

**Verified Contract:** [View on Etherscan](https://etherscan.io/token/0x3619a9103397121B6157859504637689b5C67C3a#code)  
**Source:** [`contracts/IS21Engine.sol`](https://github.com/dev-intershare/intershare-smart-contract/blob/main/src/IS21Engine.sol)

---

### 💰 ISLoanEngine

The **InterShare Lending Protocol**, enabling decentralized lending, borrowing, and automated interest accrual.  
It leverages the IS21 token as a base collateral unit and integrates dual-source oracles for price accuracy.

**Highlights:**

- **Collateralized Lending & Borrowing:** supports multi-asset deposits and loans
- **Dynamic Health Factor:** real-time solvency monitoring
- **Interest Accrual:** per-second compounding via supply/borrow indices
- **Oracle Integration:** Chainlink + Pyth dual-source oracle with fallback
- **Liquidations:** third-party participants maintain solvency and earn bonuses
- **Role-Based Governance:** Owner / Fund Manager separation
- **Pausing & Reentrancy Protection:** all external calls guarded
- **Comprehensive Test Suite:** 30+ passing unit tests covering all flows

**Verified Contract:** [View on Etherscan](TBA)
**Source:** [`contracts/ISLoanEngine.sol`](https://github.com/dev-intershare/intershare-smart-contract/blob/main/src/ISLoanEngine.sol)

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
