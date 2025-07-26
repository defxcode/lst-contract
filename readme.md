# Liquid Staking Protocol

## Overview
This is a decentralized liquid staking protocol that allows users to stake an underlying asset (e.g., rETH) in exchange for a yield-bearing Liquid Staking Token (LST). The value of the LST increases over time as staking rewards are added to the system, distributed through a time-vested index mechanism.

The protocol is designed to be modular, secure, and highly configurable through administrative roles.

## Core Contracts
* **LSTokenVault**: The central vault where users deposit underlying assets to mint LSTokens. It manages the core accounting, yield distribution, and custodian fund transfers.
* **LSToken**: The ERC20 liquid staking token that represents a user's share in the vault. Its value appreciates as yield is added to the system.
* **UnstakeManager**: Manages the entire withdrawal process, which includes a user-initiated request, a cooldown period, and the final claim.
* **TokenSilo**: A temporary holding contract where funds are placed during the unstaking cooldown period before they can be claimed by the user.
* **EmergencyController**: A global, system-wide contract that provides powerful tools to pause activity and manage the protocol during emergencies.
* **VaultFactory**: A factory contract used by the administrator to deploy and configure a complete new set of liquid staking contracts for a new underlying asset.

## Architecture & Design
The system's modular architecture separates key functionalities into distinct, upgradeable contracts. This enhances security, simplifies maintenance, and allows for granular control over the protocol.

* **Yield Mechanism**: Yield is added to the vault through an `addYield` function. To prevent price manipulation, the resulting increase in the LSToken's value (the "index") is vested linearly over a period of 8 hours.
* **Fund Management**: The protocol is designed to work with off-chain custodians. A configurable `floatPercent` determines what portion of new deposits is kept in the vault for liquidity, with the remainder being distributed to custodian wallets based on their individual allocation percentages.
* **Asynchronous Unstaking**: The unstaking process is asynchronous. An administrator processes requests, which moves the funds from the vault to the silo. A check, `require(vault.balance >= amount)`, ensures the silo is never under-funded.
* **Emergency Safeguards**: The system includes a multi-tiered emergency response system, from operational toggles in individual vaults to a global, time-locked Recovery Mode for severe incidents.

## Complete User Flows

### Staking Flow
1.  A user calls `deposit()` on the `LSTokenVault`, sending their underlying tokens.
2.  The vault calculates and mints the appropriate amount of LSTokens for the user based on the current `index`.
3.  The underlying tokens are then distributed between the vault's float and the designated custodians.

### Unstaking Flow
1.  A user calls `requestUnstake()` on the `LSTokenVault`, which burns their LSTokens.
2.  The request is sent to the `UnstakeManager`, which adds it to a queue and calculates the amount of underlying tokens owed based on the index at that moment.
3.  An administrator calls `processUnstakeQueue()`, which moves the owed funds from the vault to the `TokenSilo`.
4.  After a mandatory cooldown period ends, the user calls `claim()` on the `UnstakeManager` to receive their underlying tokens from the `TokenSilo`.

### Early Withdrawal Flow
1.  A user with funds in the `TokenSilo` can choose to bypass the remaining cooldown.
2.  They call `earlyWithdraw()` on the `TokenSilo`.
3.  A percentage-based fee is deducted, and the user immediately receives the remaining amount of their underlying tokens.

## Manager & Admin Flows

### Operational Management (`MANAGER_ROLE`)
* **Process Unstake Queue**: A manager calls `markRequestsForProcessing` and `processUnstakeQueue` on the `UnstakeManager` to move funds from the vault to the silo for users waiting to claim.
* **Add Yield**: A manager (or designated `REWARDER_ROLE`) calls `addYield` on the `LSTokenVault` to distribute staking rewards to all LSToken holders. A protocol fee is taken from the yield.
* **Withdraw Protocol Fees**: A manager calls `withdrawFees` on the `LSTokenVault` to transfer all accrued fees to the designated `feeReceiver` wallet.

### Parameter Configuration (`ADMIN_ROLE`)
* **Vault Parameters**: Admins can set all core financial parameters on the `LSTokenVault`, including `setMaxTotalDeposit`, `setMaxUserDeposit`, `setFeePercent`, and `setFloatPercent`.
* **Unstake/Silo Parameters**: Admins control the `cooldownPeriod` on the `UnstakeManager` and all `TokenSilo` settings, such as the `unlockFee` for early withdrawals and the address of the `feeCollector`.

### Security & Risk Management (`ADMIN_ROLE`)
* **Flash Loan Protection**: Admins can configure the `maxTransactionPercentage` and `maxPriceImpactPercentage` on the `LSTokenVault` to protect against manipulation.
* **Silo Security**: Admins can set the `LiquidityThreshold` (which automatically pauses withdrawals if liquidity is low) and the `Max Txn Percentage` for early withdrawals on the `TokenSilo`.

### Emergency Management (`ADMIN_ROLE` / `EMERGENCY_ROLE`)
* **Operational Toggles**: For routine maintenance, an admin can use `setStakeEnabled` and `setUnstakeEnabled` on the `LSTokenVault` to gracefully pause specific functions.
* **Emergency Pause**: For a potential threat, an admin can use the `EmergencyController` to instantly call `pauseDeposits`, `pauseWithdrawals`, or `pauseAll`.
* **Circuit Breaker**: For a severe exploit, `triggerCircuitBreaker` instantly puts the system in `FULL_PAUSE` and simultaneously starts the 24-hour timelock for the more restrictive Recovery Mode.
* **Recovery Mode**: After the 24-hour timelock, `activateRecoveryMode` can be called. This mode freezes almost all functions, including most admin controls, to allow for a secure resolution. Only an admin can `deactivateRecoveryMode`.

### Manual Overrides (`ADMIN_ROLE`)
* **Rescue Tokens**: An admin can call `rescueTokens` on the `TokenSilo` to withdraw any accidentally sent tokens to a safe address.
* **Adjust Claims**: If the silo's internal accounting ever becomes inaccurate, an admin can use `adjustPendingClaims` to manually correct the value of total pending withdrawals.