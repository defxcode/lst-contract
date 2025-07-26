// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IVaultManager.sol";
import "./interfaces/ITokenSilo.sol";
import "./interfaces/IEmergencyController.sol";
import "./interfaces/IUnstakeManager.sol";

/**
 * @title VaultManager
 * @notice Administrative control module for multi-token LST vaults
 */
contract VaultManager is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IVaultManager 
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    
    // --- Constants ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 public constant MAX_FEE_PERCENT = 30; // 30% max fee
    uint256 public constant PERCENT_PRECISION = 100;
    
    // --- State Variables ---
    // Core contract references
    address public vault;
    IERC20Upgradeable public underlyingToken;
    ITokenSilo public silo;
    IEmergencyController public emergencyController;
    IUnstakeManager public unstakeManager;
    
    // Token metadata
    string public underlyingSymbol;
    string public lsTokenSymbol;
    
    // Administrative account
    address public stakingPauser;
    
    // Fee configuration
    uint256 public feePercent;
    address public feeReceiver;
    uint256 public totalFeeCollected;
    
    // Asset management
    address public custodianWallet;
    uint256 public floatPercent;
    
    // Limits configuration
    uint256 public maxTotalDeposit;
    uint256 public maxUserDeposit;
    uint256 public minUnstakeAmount;
    
    // Enabled flags
    bool public stakeEnabled;
    bool public unstakeEnabled;
    
    // Rate limiting
    struct DailyLimit {
        uint256 maxAmount;
        uint256 currentAmount;
        uint256 windowStartTime;
    }
    
    DailyLimit public depositLimit;
    DailyLimit public withdrawalLimit;
    
    // Flash loan protection
    uint256 public maxTransactionPercentage;
    uint256 public maxPriceImpactPercentage;
    
    // Version and upgrade controls
    string public version;
    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    uint256 public upgradeRequestTime;
    bool public upgradeRequested;
    
    // Events
    event VersionUpdated(string newVersion);
    event UpgradeRequested(uint256 requestTime);
    event UpgradeCancelled(uint256 requestTime);
    event UpgradeAuthorized(address indexed implementation, string currentVersion);
    event VaultSet(address indexed vault);
    event EmergencyControllerSet(address indexed controller);
    event UnstakeManagerSet(address indexed unstakeManager);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the admin module
     */
    function initialize(
        address _vault, 
        address _underlyingToken, 
        string memory _underlyingSymbol,
        string memory _lsTokenSymbol,
        address _admin
    ) external initializer {
        require(_vault != address(0), "VaultManager: invalid vault");
        require(_underlyingToken != address(0), "VaultManager: invalid underlying token");
        require(_admin != address(0), "VaultManager: invalid admin");
        
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        vault = _vault;
        underlyingToken = IERC20Upgradeable(_underlyingToken);
        underlyingSymbol = _underlyingSymbol;
        lsTokenSymbol = _lsTokenSymbol;
        
        // Set roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        
        // Set default values
        feePercent = 10; // 10% fee
        maxTotalDeposit = 1_000_000 ether; // 1 million underlying tokens
        maxUserDeposit = 10_000 ether; // 10,000 underlying tokens
        minUnstakeAmount = 0.1 ether; // 0.1 LS token
        floatPercent = 10; // 10% float
        stakeEnabled = true;
        unstakeEnabled = true;
        
        // Set initial state
        feeReceiver = _admin;
        stakingPauser = _admin;
        custodianWallet = _admin;
        
        // Set rate limiting defaults
        depositLimit = DailyLimit({
            maxAmount: 100_000 ether, // Default 100k underlying tokens max daily deposit
            currentAmount: 0,
            windowStartTime: block.timestamp
        });
        
        withdrawalLimit = DailyLimit({
            maxAmount: 50_000 ether, // Default 50k underlying tokens max daily withdrawal
            currentAmount: 0,
            windowStartTime: block.timestamp
        });
        
        // Set flash loan protection defaults
        maxTransactionPercentage = 5; // Default 5% of total supply per transaction
        maxPriceImpactPercentage = 3; // Default 3% max price impact
        
        version = "1.0.0";
    }
    
    /**
     * @notice Set the emergency controller
     */
    function setEmergencyController(address _emergencyController) external onlyRole(ADMIN_ROLE) {
        require(_emergencyController != address(0), "VaultManager: invalid controller");
        emergencyController = IEmergencyController(_emergencyController);
        emit EmergencyControllerSet(_emergencyController);
    }
    
    /**
     * @notice Set the unstake manager
     */
    function setUnstakeManager(address _unstakeManager) external onlyRole(ADMIN_ROLE) {
        require(_unstakeManager != address(0), "VaultManager: invalid unstake manager");
        unstakeManager = IUnstakeManager(_unstakeManager);
        emit UnstakeManagerSet(_unstakeManager);
    }

    /**
     * @notice Set silo address
     */
    function setSilo(address _silo) external override onlyRole(ADMIN_ROLE) {
        require(_silo != address(0), "VaultManager: invalid silo");
        silo = ITokenSilo(_silo);
        emit SiloSet(_silo);
    }
    
    /**
     * @notice Set cooldown period
     */
    function setCooldownPeriod(uint256 _cooldown) external override onlyRole(ADMIN_ROLE) {
        require(address(unstakeManager) != address(0), "VaultManager: unstake manager not set");
        unstakeManager.setCooldownPeriod(_cooldown);
        emit CooldownPeriodSet(_cooldown);
    }
    
    /**
     * @notice Set fee percentage
     */
    function setFeePercent(uint256 _feePercent) external override onlyRole(ADMIN_ROLE) {
        require(_feePercent <= MAX_FEE_PERCENT, "VaultManager: fee too high");
        feePercent = _feePercent;
        emit FeePercentSet(_feePercent);
    }
    
    /**
     * @notice Set fee receiver
     */
    function setFeeReceiver(address _feeReceiver) external override onlyRole(ADMIN_ROLE) {
        require(_feeReceiver != address(0), "VaultManager: invalid fee receiver");
        feeReceiver = _feeReceiver;
        emit FeeReceiverSet(_feeReceiver);
    }
    
    /**
     * @notice Set staking pauser
     */
    function setStakingPauser(address _stakingPauser) external override onlyRole(ADMIN_ROLE) {
        require(_stakingPauser != address(0), "VaultManager: invalid address");
        stakingPauser = _stakingPauser;
        emit StakingPauserSet(_stakingPauser);
    }
    
    /**
     * @notice Set maximum total deposits
     */
    function setMaxTotalDeposit(uint256 _maxTotalDeposit) external override onlyRole(ADMIN_ROLE) {
        maxTotalDeposit = _maxTotalDeposit;
        emit MaxTotalDepositSet(_maxTotalDeposit);
    }
    
    /**
     * @notice Set maximum user deposits
     */
    function setMaxUserDeposit(uint256 _maxUserDeposit) external override onlyRole(ADMIN_ROLE) {
        maxUserDeposit = _maxUserDeposit;
        emit MaxUserDepositSet(_maxUserDeposit);
    }
    
    /**
     * @notice Set minimum unstake amount
     */
    function setMinUnstakeAmount(uint256 _minUnstakeAmount) external override onlyRole(ADMIN_ROLE) {
        require(_minUnstakeAmount > 0, "VaultManager: must be > 0");
        minUnstakeAmount = _minUnstakeAmount;
        // Also update unstake manager
        if (address(unstakeManager) != address(0)) {
            unstakeManager.setMinUnstakeAmount(_minUnstakeAmount);
        }
        emit MinUnstakeAmountSet(_minUnstakeAmount);
    }
    
    /**
     * @notice Set custodian wallet
     */
    function setCustodianWallet(address _custodianWallet) external override onlyRole(ADMIN_ROLE) {
        require(_custodianWallet != address(0), "VaultManager: invalid custodian wallet");
        custodianWallet = _custodianWallet;
        emit CustodianWalletSet(_custodianWallet);
    }
    
    /**
     * @notice Set float percentage
     */
    function setFloatPercent(uint256 _floatPercent) external override onlyRole(ADMIN_ROLE) {
        require(_floatPercent <= PERCENT_PRECISION, "VaultManager: invalid float percentage");
        floatPercent = _floatPercent;
        emit FloatPercentSet(_floatPercent);
    }
    
    /**
     * @notice Set staking enabled
     */
    function setStakeEnabled(bool _enabled) external override {
        require(
            msg.sender == stakingPauser || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "VaultManager: not authorized"
        );
        stakeEnabled = _enabled;
        emit StakeEnabledSet(_enabled);
    }
    
    /**
     * @notice Set unstaking enabled
     */
    function setUnstakeEnabled(bool _enabled) external override {
        require(
            msg.sender == stakingPauser || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "VaultManager: not authorized"
        );
        unstakeEnabled = _enabled;
        emit UnstakeEnabledSet(_enabled);
    }
    
    /**
     * @notice Pause system (via the vault)
     */
    function pause() external override onlyRole(ADMIN_ROLE) {
        emit PauseRequested();
    }
    
    /**
     * @notice Unpause system (via the vault)
     */
    function unpause() external override onlyRole(ADMIN_ROLE) {
        emit UnpauseRequested();
    }
    
    /**
     * @notice Withdraw collected fees
     */
    function withdrawFees() external override onlyRole(MANAGER_ROLE) nonReentrant {
        require(feeReceiver != address(0), "VaultManager: fee receiver not set");
        
        uint256 feeAmount = totalFeeCollected;
        require(feeAmount > 0, "VaultManager: no fees to withdraw");
        require(feeAmount <= underlyingToken.balanceOf(address(this)), "VaultManager: insufficient balance");
        
        // Update state before external call
        totalFeeCollected = 0;
        
        // External call happens after state modifications
        underlyingToken.safeTransfer(feeReceiver, feeAmount);
    }
    
    /**
     * @notice Transfer underlying tokens to custodian
     */
    function transferToCustodian(uint256 amount) external override onlyRole(ADMIN_ROLE) nonReentrant {
        require(custodianWallet != address(0), "VaultManager: custodian wallet not set");
        require(amount > 0, "VaultManager: amount must be > 0");
        
        uint256 balance = underlyingToken.balanceOf(address(this));
        require(amount <= balance, "VaultManager: insufficient balance");
        
        underlyingToken.safeTransfer(custodianWallet, amount);
        emit CustodianTransfer(custodianWallet, amount);
    }
    
    /**
     * @notice Transfer collateral to any address
     */
    function transferCollateral(address to, uint256 amount) external override onlyRole(ADMIN_ROLE) nonReentrant {
        require(to != address(0), "VaultManager: invalid recipient");
        require(amount > 0, "VaultManager: amount must be > 0");
        
        uint256 balance = underlyingToken.balanceOf(address(this));
        require(amount <= balance, "VaultManager: insufficient balance");
        
        underlyingToken.safeTransfer(to, amount);
        emit TreasuryWithdrawn(to, amount);
    }
    
    /**
     * @notice Set rate limits
     */
    function setRateLimits(
        uint256 _maxDailyDepositAmount, 
        uint256 _maxDailyWithdrawalAmount
    ) external override onlyRole(ADMIN_ROLE) {
        depositLimit.maxAmount = _maxDailyDepositAmount;
        withdrawalLimit.maxAmount = _maxDailyWithdrawalAmount;
        emit RateLimitUpdated(_maxDailyDepositAmount, _maxDailyWithdrawalAmount);
    }
    
    /**
     * @notice Reset daily limit
     */
    function resetDailyLimit(bool isDeposit) external override onlyRole(ADMIN_ROLE) {
        if (isDeposit) {
            depositLimit.currentAmount = 0;
            depositLimit.windowStartTime = block.timestamp;
        } else {
            withdrawalLimit.currentAmount = 0;
            withdrawalLimit.windowStartTime = block.timestamp;
        }
        
        emit DailyLimitReset(isDeposit, block.timestamp);
    }
    
    /**
     * @notice Set flash loan protection
     */
    function setFlashLoanProtection(
        uint256 _maxTransactionPercentage, 
        uint256 _maxPriceImpactPercentage
    ) external override onlyRole(ADMIN_ROLE) {
        require(_maxTransactionPercentage <= 50, "VaultManager: percentage too high");
        require(_maxPriceImpactPercentage <= 20, "VaultManager: impact too high");
        
        maxTransactionPercentage = _maxTransactionPercentage;
        maxPriceImpactPercentage = _maxPriceImpactPercentage;
        
        emit FlashLoanProtectionUpdated(_maxTransactionPercentage, _maxPriceImpactPercentage);
    }
    
    // View functions
    
    function getSiloAddress() external view override returns (address) {
        return address(silo);
    }
    
    function getFeeSettings() external view override returns (
        uint256 _feePercent, 
        address _feeReceiver, 
        uint256 _feeCollected
    ) {
        return (feePercent, feeReceiver, totalFeeCollected);
    }
    
    function getLimits() external view override returns (
        uint256 _maxTotalDeposit, 
        uint256 _maxUserDeposit, 
        uint256 _minUnstakeAmount
    ) {
        return (maxTotalDeposit, maxUserDeposit, minUnstakeAmount);
    }
    
    function getRateLimits() external view override returns (
        uint256 _maxDailyDepositAmount, 
        uint256 _currentDailyDeposit,
        uint256 _maxDailyWithdrawalAmount, 
        uint256 _currentDailyWithdrawal
    ) {
        return (
            depositLimit.maxAmount,
            depositLimit.currentAmount,
            withdrawalLimit.maxAmount,
            withdrawalLimit.currentAmount
        );
    }
    
    function requestUpgrade() external onlyRole(ADMIN_ROLE) {
        if (upgradeRequested) {
            require(block.timestamp >= upgradeRequestTime + UPGRADE_TIMELOCK, 
                "Previous upgrade request still in timelock period");
        }
        upgradeRequestTime = block.timestamp;
        upgradeRequested = true;
        emit UpgradeRequested(upgradeRequestTime);
    }
    
    function cancelUpgrade() external onlyRole(ADMIN_ROLE) {
        require(upgradeRequested, "No upgrade to cancel");
        upgradeRequested = false;
        emit UpgradeCancelled(upgradeRequestTime);
        upgradeRequestTime = 0;
    }
    
    function updateVersion(string memory _newVersion) external onlyRole(ADMIN_ROLE) {
        version = _newVersion;
        emit VersionUpdated(_newVersion);
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        require(newImplementation != address(0), "VaultManager: invalid implementation");
        require(upgradeRequested, "VaultManager: upgrade not requested");
        require(block.timestamp >= upgradeRequestTime + UPGRADE_TIMELOCK, "VaultManager: timelock not expired");
        
        upgradeRequested = false;
        emit UpgradeAuthorized(newImplementation, version);
    }
    
    // Events not defined in the interface
    event PauseRequested();
    event UnpauseRequested();
    
    uint256[20] private __gap;
}