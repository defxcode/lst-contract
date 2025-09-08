// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// External libraries and contracts
import { UD60x18, wrap, unwrap } from "@prb/math/src/UD60x18.sol";
// For high-precision math
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// Internal interfaces and contracts
import "./interfaces/ILSToken.sol";
import "./interfaces/IUnderlyingToken.sol";
import "./interfaces/ITokenSilo.sol";
import "./interfaces/IUnstakeManager.sol";
import "./interfaces/IEmergencyController.sol";
import "./LSTokenVaultStorage.sol";
// Inherits all storage variables

/**
* @title LSTokenVault
* @notice The core contract of the protocol, managing user deposits, yield distribution, and custodian fund transfers.
* @dev Inherits its state from LSTokenVaultStorage to separate logic and storage for upgradeability.
*/
contract LSTokenVault is
Initializable,
AccessControlUpgradeable,
PausableUpgradeable,
ReentrancyGuardUpgradeable,
UUPSUpgradeable,
LSTokenVaultStorage
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    // --- State Variables (Interfaces) ---

    /// @notice The contract that manages the unstaking process.
    IUnstakeManager public unstakeManager;
    /// @notice The global emergency controller contract.
    IEmergencyController public emergencyController;
    // --- Upgrade Control ---
    string public version;
    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    uint256 public upgradeRequestTime;
    bool public upgradeRequested;

    // --- Events ---
    event UnstakeManagerSet(address indexed unstakeManager);
    event EmergencyControllerSet(address indexed emergencyController);
    event Deposited(address indexed user, uint256 underlyingAmount, uint256 lsTokenAmount);
    event FeesWithdrawn(address indexed receiver, uint256 amount);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the LSTokenVault with its core parameters and roles.
     * @dev Called only once by the VaultFactory upon deployment.
     */
    function initialize(
        address _underlyingToken,
        address _lsToken,
        string memory _underlyingSymbol,
        string memory _lsTokenSymbol,
        address _admin
    ) external initializer {
        require(_underlyingToken != address(0), "Invalid underlying token");
        require(_lsToken != address(0), "Invalid LS token");
        require(_admin != address(0), "Invalid admin");

        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        underlyingToken = IERC20Upgradeable(_underlyingToken);
        lsToken = ILSToken(_lsToken);
        underlyingSymbol = _underlyingSymbol;
        lsTokenSymbol = _lsTokenSymbol;

        // The index represents the exchange rate, starting at 1:1.
        lastIndex = INITIAL_INDEX;
        targetIndex = INITIAL_INDEX;
        lastUpdateTime = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(REWARDER_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        _setupDefaults(_admin);
        version = "1.0.0";
    }

    // --- Contract Links Setup ---

    /**
     * @notice Sets the address of the UnstakeManager contract.
     * @dev A critical setup function to enable the unstaking process. Can only be called by an admin.
     * @param _unstakeManager The address of the deployed UnstakeManager.
    */
    function setUnstakeManager(address _unstakeManager) external onlyRole(ADMIN_ROLE) {
        require(_unstakeManager != address(0), "Invalid unstake manager");
        unstakeManager = IUnstakeManager(_unstakeManager);
        emit UnstakeManagerSet(_unstakeManager);
    }

    /**
     * @notice Sets the address of the global EmergencyController contract.
     * @dev Links the vault to the system's central kill switch. Can only be called by an admin.
     * @param _emergencyController The address of the deployed EmergencyController.
    */
    function setEmergencyController(address _emergencyController) external onlyRole(ADMIN_ROLE) {
        require(_emergencyController != address(0), "Invalid emergency controller");
        emergencyController = IEmergencyController(_emergencyController);
        emit EmergencyControllerSet(_emergencyController);
    }

    // --- Core Logic ---

    /**
     * @notice Calculates the current value of the LSToken index, accounting for linear vesting of yield.
     * @dev To prevent flash loan manipulation, yield is vested over `YIELD_VESTING_DURATION`.
     * This function smoothly interpolates the index value between `lastIndex` and `targetIndex`.
     * @return The current, time-vested index representing the LSToken's value.
     */
    function getCurrentIndex() public view returns (uint256) {
        if (block.timestamp >= vestingEndTime || vestingEndTime == 0) return targetIndex;
        if (vestingEndTime <= lastUpdateTime) return targetIndex;

        uint256 elapsed = block.timestamp - lastUpdateTime;
        uint256 duration = vestingEndTime - lastUpdateTime;
        uint256 delta = targetIndex - lastIndex;

        uint256 indexIncrease = calculatePercentage(delta, elapsed, duration);
        if (indexIncrease > delta) { // Safety check to prevent overshooting the target
            indexIncrease = delta;
        }

        return lastIndex + indexIncrease;
    }

    /**
     * @notice Adds staking rewards (yield) to the vault, increasing the value of the LSToken for all holders.
     * @dev Can only be called by a `REWARDER_ROLE`. Takes a protocol fee and sets a new `targetIndex`.
     * This increase in value is then vested over 8 hours via the `getCurrentIndex` logic.
     * @param yieldAmount The amount of underlying tokens being added as rewards.
     */
    function addYield(uint256 yieldAmount) external onlyRole(REWARDER_ROLE) {
        require(yieldAmount > 0, "Yield must be > 0");
        require(address(emergencyController) != address(0), "Emergency controller not set");
        require(emergencyController.getEmergencyState() == IEmergencyController.EmergencyState.NORMAL, "Emergency mode");
        require(!emergencyController.isRecoveryModeActive(), "Recovery mode active");
        require(block.timestamp >= vestingEndTime || vestingEndTime == 0, "Previous yield vesting");

        uint256 supply = lsToken.totalSupply();
        require(supply > 0, "No LS token supply");

        uint256 feeAmount = calculatePercentage(yieldAmount, feePercent, PERCENT_PRECISION);
        uint256 distributableYield = yieldAmount - feeAmount;
        // Add any previously forfeited yield to the distributable amount.
        if (unclaimedYield > 0) {
            distributableYield += unclaimedYield;
            unclaimedYield = 0;
        }
        if (feeAmount > 0 && feeReceiver != address(0)) {
            totalFeeCollected += feeAmount;
            emit FeesCollected(feeAmount);
        }

        totalCustodianFunds += yieldAmount;

        uint256 current = getCurrentIndex();
        uint256 deltaIndex = calculatePercentage(distributableYield, INDEX_PRECISION, supply);

        uint256 maxIndexIncrease = calculatePercentage(current, MAX_INDEX_INCREASE_PERCENT, PERCENT_PRECISION);
        require(deltaIndex <= maxIndexIncrease, "Yield too high");
        uint256 newTarget = current + deltaIndex;

        uint256 indexChangePercent = calculatePercentage(deltaIndex, 100, current);
        require(indexChangePercent <= maxPriceImpactPercentage, "Index change too high");
        uint256 oldIndex = lastIndex;
        lastIndex = current;
        targetIndex = newTarget;
        lastUpdateTime = block.timestamp;
        vestingEndTime = block.timestamp + YIELD_VESTING_DURATION;
        lastStateUpdate = block.timestamp;

        emit IndexUpdated(oldIndex, newTarget);
    }

    /**
     * @notice The main function for users to deposit underlying assets and mint LSTokens.
     * @param underlyingAmount The amount of the underlying token the user wants to stake.
     */
    function deposit(uint256 underlyingAmount) external whenNotPaused nonReentrant {
        _deposit(msg.sender, underlyingAmount, 0);
    }

    /**
     * @notice Overloaded deposit function with slippage protection.
     * @param underlyingAmount The amount of the underlying token to stake.
     * @param minLSTokenAmount The minimum amount of LSTokens the user will accept.
     */
    function deposit(uint256 underlyingAmount, uint256 minLSTokenAmount) external whenNotPaused nonReentrant {
        _deposit(msg.sender, underlyingAmount, minLSTokenAmount);
    }

    /**
     * @notice Allows a `MANAGER_ROLE` to deposit on behalf of another user.
     * @param user The address that will receive the minted LSTokens.
     * @param underlyingAmount The amount of the underlying token to stake.
     */
    function depositFor(address user, uint256 underlyingAmount) external whenNotPaused nonReentrant onlyRole(MANAGER_ROLE){
        _deposit(user, underlyingAmount, 0);
    }

    /**
     * @notice Internal logic for handling all deposits.
     * @dev Performs all security checks, calculates the LSToken amount, mints tokens, and triggers custodian transfers.
     */
    function _deposit(address user, uint256 underlyingAmount, uint256 minLSTokenAmount) internal {
        require(address(emergencyController) != address(0), "Emergency controller not set");
        IEmergencyController.EmergencyState state = emergencyController.getEmergencyState();
        require(state != IEmergencyController.EmergencyState.DEPOSITS_PAUSED &&
        state != IEmergencyController.EmergencyState.FULL_PAUSE, "Deposits paused");
        require(!emergencyController.isRecoveryModeActive(), "Recovery mode active");
        require(stakeEnabled, "Staking disabled");
        require(underlyingAmount >= MIN_DEPOSIT_AMOUNT, "Below minimum");
        require(user != address(0), "Invalid user");
        require(totalDepositedAmount + underlyingAmount <= maxTotalDeposit, "Global limit reached");

        uint256 userBalance = lsToken.balanceOf(user);
        uint256 currentIndex = getCurrentIndex();
        uint256 existingValue = convertTokens(userBalance, currentIndex, INDEX_PRECISION, false);
        require(existingValue + underlyingAmount <= maxUserDeposit, "User limit reached");

        _validateRateLimit(underlyingAmount, true);

        // using targetIndex for deposits to prevent new depositors from
        // unfairly benefiting from yield generated by previous stakers.
        uint256 depositIndex = targetIndex;
        uint256 lsTokenAmount = convertTokens(underlyingAmount, depositIndex, INDEX_PRECISION, true);
        if (minLSTokenAmount > 0) {
            require(lsTokenAmount >= minLSTokenAmount, "Slippage too high");
        }
        require(lsTokenAmount > 0, "LS token amount is 0");

        totalDepositedAmount += underlyingAmount;
        lastStateUpdate = block.timestamp;

        // Recording the user's deposit time to enforce the withdrawal lock.
        lastDepositTime[user] = block.timestamp;

        underlyingToken.safeTransferFrom(msg.sender, address(this), underlyingAmount);
        lsToken.mint(user, lsTokenAmount);

        _handleCustodianTransfer(underlyingAmount);

        emit Deposited(user, underlyingAmount, lsTokenAmount);
    }

    /**
     * @notice Internal function to distribute a portion of new deposits to the custodian wallets.
     * @dev Iterates through custodians and transfers funds based on their configured allocation percentage.
     * The remainder is kept in the vault as a "float" for liquidity.
     * @param underlyingAmount The amount to be distributed.
    */
    function _handleCustodianTransfer(uint256 underlyingAmount) internal {
        if (custodians.length == 0 || emergencyController.isRecoveryModeActive()) return;
        for (uint256 i = 0; i < custodians.length; i++) {
            if (custodians[i].wallet == address(0)) continue;
            uint256 allocation = allocationToPercent(custodians[i].allocation);

            uint256 custodianAmount = calculatePercentage(underlyingAmount, allocation, 100);
            if (custodianAmount > 0) {
                totalCustodianFunds += custodianAmount;
                underlyingToken.safeTransfer(custodians[i].wallet, custodianAmount);
                emit CustodianTransfer(i, custodians[i].wallet, custodianAmount);
            }
        }
    }

    /**
     * @notice Initiates the unstaking process for the user.
     * @dev Delegates the request to the `UnstakeManager`.
    * @param lsTokenAmount The amount of LSTokens the user wishes to redeem.
     */
    function requestUnstake(uint256 lsTokenAmount) external nonReentrant {
        _requestUnstake(lsTokenAmount, 0);
    }

    /**
     * @notice Overloaded `requestUnstake` with slippage protection.
     * @param lsTokenAmount The amount of LSTokens to redeem.
    * @param minUnderlyingAmount The minimum amount of underlying tokens the user will accept.
     */
    function requestUnstake(uint256 lsTokenAmount, uint256 minUnderlyingAmount) external nonReentrant {
        _requestUnstake(lsTokenAmount, minUnderlyingAmount);
    }

    /**
     * @notice Internal logic for handling all unstake requests.
     */
    function _requestUnstake(uint256 lsTokenAmount, uint256 minUnderlyingAmount) internal {
        require(address(unstakeManager) != address(0), "Unstake manager not set");
        require(address(emergencyController) != address(0), "Emergency controller not set");

        IEmergencyController.EmergencyState state = emergencyController.getEmergencyState();
        require(state != IEmergencyController.EmergencyState.WITHDRAWALS_PAUSED &&
        state != IEmergencyController.EmergencyState.FULL_PAUSE, "Withdrawals paused");
        require(!emergencyController.isRecoveryModeActive(), "Recovery mode active");
        require(unstakeEnabled, "Unstaking disabled");

        _validateRateLimit(lsTokenAmount, false);

        // Enforcing a withdrawal lock for a duration equal to the yield vesting period.
        require(block.timestamp >= lastDepositTime[msg.sender] + YIELD_VESTING_DURATION, "Withdrawal lock active");

        // If unstaking during a vesting period, capture the forfeited yield for redistribution.
        uint256 currentIndex = getCurrentIndex();
        if (currentIndex < targetIndex) {
            uint256 currentValue = convertTokens(lsTokenAmount, currentIndex, INDEX_PRECISION, false);
            uint256 targetValue = convertTokens(lsTokenAmount, targetIndex, INDEX_PRECISION, false);

            if (targetValue > currentValue) {
                unclaimedYield += (targetValue - currentValue);
            }
        }

        unstakeManager.requestUnstake(msg.sender, lsTokenAmount, minUnderlyingAmount, currentIndex);
    }

    // --- Custodian Management (ADMIN_ROLE) ---
    // These functions are called directly by an admin to manage the off-chain custodian wallets.
    function addCustodian(address wallet, uint256 allocationPercent) external onlyRole(ADMIN_ROLE) returns (uint256 custodianId) {
        require(address(emergencyController) == address(0) || !emergencyController.isRecoveryModeActive(), "Recovery mode");
        return _addCustodian(wallet, allocationPercent);
    }

    function updateCustodian(uint256 custodianId, address wallet, uint256 allocationPercent) external onlyRole(ADMIN_ROLE) {
        require(address(emergencyController) == address(0) || !emergencyController.isRecoveryModeActive(), "Recovery mode");
        _updateCustodian(custodianId, wallet, allocationPercent);
    }

    function removeCustodian(uint256 custodianId) external onlyRole(ADMIN_ROLE) {
        require(address(emergencyController) == address(0) || !emergencyController.isRecoveryModeActive(), "Recovery mode");
        _removeCustodian(custodianId);
    }

    function getCustodian(uint256 custodianId) external view returns (address wallet, uint256 allocationPercent) {
        if (custodianId >= custodians.length) return (address(0), 0);
        return (custodians[custodianId].wallet, _getCustodianAllocation(custodianId));
    }

    function getAllCustodians() external view returns (address[] memory wallets, uint256[] memory allocations) {
        return _getAllCustodians();
    }

    // --- Admin & Manager Functions ---

    /**
     * @notice Sets the percentage of new deposits to be kept in the vault for liquidity.
     */
    function setFloatPercent(uint256 _floatPercent) external onlyRole(MANAGER_ROLE) {
        require(_floatPercent <= 100, "Invalid float percentage");
        uint256 totalCustodianAllocation = 0;
        for (uint256 i = 0; i < custodians.length; i++) {
            totalCustodianAllocation += allocationToPercent(custodians[i].allocation);
        }
        require(_floatPercent + totalCustodianAllocation <= 100,
            "Float percentage and custodian allocations cannot exceed 100%");
        floatPercent = uint8(_floatPercent);
    }

    /**
     * @notice Allows an admin to correct the on-chain accounting when custodians return funds to the vault.
     */
    function recordCustodianFundsReturn(uint256 amount) external onlyRole(MANAGER_ROLE) {
        require(amount <= totalCustodianFunds, "Amount exceeds custodian funds");
        totalCustodianFunds -= amount;
    }

    /**
     * @notice Sets the daily deposit and withdrawal rate limits.
     */
    function setRateLimits(uint256 _maxDailyDeposit, uint256 _maxDailyWithdrawal) external onlyRole(MANAGER_ROLE) {
        depositLimit.maxAmount = uint128(_maxDailyDeposit);
        withdrawalLimit.maxAmount = uint128(_maxDailyWithdrawal);
    }

    /**
     * @notice Configures the parameters for flash loan protection.
     */
    function setFlashLoanProtection(uint256 _maxTransactionPercentage, uint256 _maxPriceImpactPercentage) external onlyRole(MANAGER_ROLE) {
        require(_maxTransactionPercentage <= 5000, "Percentage too high");
        require(_maxPriceImpactPercentage <= 2000, "Impact too high");
        maxTransactionPercentage = uint16(_maxTransactionPercentage);
        maxPriceImpactPercentage = uint16(_maxPriceImpactPercentage);
    }

    /**
     * @notice Allows an admin to approve the UnstakeManager to spend the vault's underlying tokens.
     */
    function approveUnstakeManager(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(address(unstakeManager) != address(0), "Unstake manager not set");
        // To support tokens like USDT, first reset the allowance to 0.
        underlyingToken.safeApprove(address(unstakeManager), 0);
        underlyingToken.safeApprove(address(unstakeManager), amount);
    }

    /**
     * @notice Allows a `MANAGER_ROLE` to withdraw all accrued protocol fees.
     */
    function withdrawFees() external nonReentrant onlyRole(MANAGER_ROLE){
        require(feeReceiver != address(0), "LSTokenVault: fee receiver not set");
        uint256 amountToWithdraw = totalFeeCollected;
        require(amountToWithdraw > 0, "LSTokenVault: no fees to withdraw");
        require(underlyingToken.balanceOf(address(this)) >= amountToWithdraw, "LSTokenVault: insufficient vault balance for fees");

        totalFeeCollected = 0;

        underlyingToken.safeTransfer(feeReceiver, amountToWithdraw);
        emit FeesWithdrawn(feeReceiver, amountToWithdraw);
    }


    // --- View Functions ---

    function previewDeposit(uint256 underlyingAmount) external view returns (uint256 lsTokenAmount) {
        uint256 currentIndex = getCurrentIndex();
        return convertTokens(underlyingAmount, currentIndex, INDEX_PRECISION, true);
    }

    function previewRedeem(uint256 lsTokenAmount) external view returns (uint256 underlyingAmount) {
        uint256 currentIndex = getCurrentIndex();
        return convertTokens(lsTokenAmount, currentIndex, INDEX_PRECISION, false);
    }

    function getStats() external view returns (uint256 currentIndex, uint256 totalDeposited, uint256 totalSupply) {
        return (getCurrentIndex(), totalDepositedAmount, lsToken.totalSupply());
    }

    function getLiquidityStatus() external view returns (uint256, uint256, uint256, uint256) {
        uint256 vaultBalance = underlyingToken.balanceOf(address(this));
        uint256 custodianBalance = totalCustodianFunds;
        uint256 totalAvailableAssets = vaultBalance + custodianBalance;
        uint256 lsTokenSupply = lsToken.totalSupply();
        uint256 currentIndex = getCurrentIndex();
        uint256 indexedLiabilities = convertTokens(lsTokenSupply, currentIndex, INDEX_PRECISION, false);
        return (vaultBalance, custodianBalance, totalAvailableAssets, indexedLiabilities);
    }

    function getTokenInfo() external view returns (address, address, string memory, string memory) {
        return (address(underlyingToken), address(lsToken), underlyingSymbol, lsTokenSymbol);
    }

    // --- Admin Functions (Controlled by VaultManager) ---

    /**
     * @notice Sets the maximum total deposit amount for the vault.
     * @dev Can only be called by the VaultManager contract, which has the MANAGER_ROLE.
     */
    function setMaxTotalDeposit(uint256 _maxTotal) external onlyRole(MANAGER_ROLE) {
        _setMaxTotalDeposit(_maxTotal);
    }

    /**
     * @notice Sets the maximum deposit amount for a single user.
     * @dev Can only be called by the VaultManager.
    */
    function setMaxUserDeposit(uint256 _maxUser) external onlyRole(MANAGER_ROLE) {
        _setMaxUserDeposit(_maxUser);
    }

    /**
     * @notice Sets the protocol fee percentage taken from yield.
     * @dev Can only be called by the VaultManager.
    */
    function setFeePercent(uint256 _feePercent) external onlyRole(MANAGER_ROLE) {
        _setFeePercent(_feePercent);
    }

    /**
     * @notice Sets the address that receives protocol fees.
     * @dev Can only be called by the VaultManager.
    */
    function setFeeReceiver(address _feeReceiver) external onlyRole(MANAGER_ROLE) {
        _setFeeReceiver(_feeReceiver);
    }

    /**
     * @notice Enables or disables depositing.
     * @dev Can only be called by the VaultManager.
    */
    function setStakeEnabled(bool _enabled) external onlyRole(MANAGER_ROLE) {
        _setStakeEnabled(_enabled);
    }

    /**
     * @notice Enables or disables unstaking.
     * @dev Can only be called by the VaultManager.
    */
    function setUnstakeEnabled(bool _enabled) external onlyRole(MANAGER_ROLE) {
        _setUnstakeEnabled(_enabled);
    }

    // --- Upgrade Functions ---
    function requestUpgrade() external onlyRole(ADMIN_ROLE) {
        if (upgradeRequested) {
            require(block.timestamp >= upgradeRequestTime + UPGRADE_TIMELOCK, "Previous upgrade pending");
        }
        upgradeRequestTime = block.timestamp;
        upgradeRequested = true;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        require(newImplementation != address(0), "Invalid implementation");
        require(upgradeRequested, "Upgrade not requested");
        require(block.timestamp >= upgradeRequestTime + UPGRADE_TIMELOCK, "Timelock not expired");
        upgradeRequested = false;
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        if (address(emergencyController) != address(0)) {
            require(!emergencyController.isRecoveryModeActive(), "Recovery mode active");
        }
        _unpause();
    }

    uint256[30] private __gap;
}