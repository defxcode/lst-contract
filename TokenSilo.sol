// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { UD60x18, wrap, unwrap } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IEmergencyController.sol";

/**
* @title TokenSilo
* @notice Holds underlying tokens during cooldown
*/
contract TokenSilo is 
   Initializable,
   AccessControlUpgradeable, 
   ReentrancyGuardUpgradeable, 
   PausableUpgradeable,
   UUPSUpgradeable
{
   using SafeERC20Upgradeable for IERC20Upgradeable;

   // Roles
   bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
   bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
   bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

   // Token references
   IERC20Upgradeable public underlyingToken;
   string public tokenSymbol;
   
   // Emergency controller
   IEmergencyController public emergencyController;
   
   // User deposits tracking
   mapping(address => uint256) public userDeposits;
   
   // Overall state tracking
   struct SiloState {
       uint256 totalDeposited;
       uint256 totalWithdrawn;
       uint256 totalPendingClaims;
       uint256 totalCollectedFees;
       uint256 lastActivityTimestamp;
   }
   
   SiloState public state;
   
   // Cooldown configuration 
   struct CooldownConfig {
       uint256 unlockFee;
       bool earlyUnlockEnabled;
       address feeCollector;
       bool claimsPaused;
       uint256 liquidityThreshold;
   }
   
   CooldownConfig public config;
   
   // Rate limiting
   struct RateLimit {
       uint256 maxDailyAmount;
       uint256 currentAmount;
       uint256 windowStartTime;
       uint256 maxTransactionPercentage;
   }
   
   RateLimit public withdrawalLimit;
   
   // Version and upgrade controls
   struct UpgradeControl {
       string version;
       uint256 requestTime;
       bool requested;
   }
   
   UpgradeControl public upgradeControl;
   uint256 public constant UPGRADE_TIMELOCK = 2 days;
   
   /**
    * @notice Safe wrapper for UD60x18 with bounds checking
    */
   function safeWrap(uint256 value) internal pure returns (UD60x18) {
       require(value <= type(uint256).max / 1e18, "Value too large for UD60x18");
       return wrap(value);
   }
   
   /**
    * @notice Safe unwrapper for UD60x18 with bounds checking
    */
   function safeUnwrap(UD60x18 value) internal pure returns (uint256) {
       uint256 result = unwrap(value);
       require(result >= 0, "UD60x18 unwrap underflow");
       return result;
   }
   
   // Events
   event Deposited(address indexed user, uint256 amount);
   event Withdrawn(address indexed user, uint256 amount);
   event EarlyWithdrawn(address indexed user, uint256 amount, uint256 fee);
   event UnlockFeeSet(uint256 fee);
   event EarlyUnlockEnabledSet(bool enabled);
   event FeeCollectorSet(address collector);
   event RescuedTokens(address token, address to, uint256 amount);
   event ClaimsPausedSet(bool paused);
   event LiquidityThresholdSet(uint256 threshold);
   event LiquidityAlert(uint256 availableAmount, uint256 neededAmount);
   event VersionUpdated(string newVersion);
   event UpgradeRequested(uint256 requestTime);
   event UpgradeAuthorized(address indexed implementation, string currentVersion);
   event UpgradeCancelled(uint256 requestTime);
   event EmergencyControllerSet(address indexed controller);
   event RateLimitUpdated(uint256 maxDailyWithdrawalAmount);
   event DailyLimitReset(uint256 timestamp);

   /// @custom:oz-upgrades-unsafe-allow constructor
   constructor() {
       _disableInitializers();
   }

   /**
    * @notice Initialize the silo contract
    * @param _underlyingToken The underlying token address
    * @param _tokenSymbol The token symbol
    * @param vault The vault address that will have VAULT_ROLE
    */
   function initialize(
       address _underlyingToken,
       string memory _tokenSymbol,
       address vault
   ) public initializer {
       require(_underlyingToken != address(0), "Silo: invalid underlying token");
       require(vault != address(0), "Silo: invalid vault");

       // Initialize parent contracts
       __ReentrancyGuard_init();
       __Pausable_init();
       __AccessControl_init();
       __UUPSUpgradeable_init();

       underlyingToken = IERC20Upgradeable(_underlyingToken);
       tokenSymbol = _tokenSymbol;
       
       _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
       _grantRole(ADMIN_ROLE, msg.sender);
       _grantRole(VAULT_ROLE, vault);
       _grantRole(EMERGENCY_ROLE, msg.sender);
       
       // Default settings
       config.unlockFee = 50; // 0.5% (in basis points, 10000 = 100%)
       config.earlyUnlockEnabled = false;
       config.feeCollector = msg.sender;
       config.claimsPaused = false;
       config.liquidityThreshold = 8000; // 80% liquidity threshold
       
       // Rate limiting defaults
       withdrawalLimit.maxDailyAmount = 50_000 ether; // Default 50k tokens max daily withdrawal
       withdrawalLimit.windowStartTime = block.timestamp;
       withdrawalLimit.maxTransactionPercentage = 5; // Default 5% of total deposits per transaction
       
       // Version control
       upgradeControl.version = "1.0.0";
   }

   /**
    * @notice Set the emergency controller
    */
   function setEmergencyController(address _emergencyController) external onlyRole(ADMIN_ROLE) {
       require(_emergencyController != address(0), "Silo: invalid controller");
       emergencyController = IEmergencyController(_emergencyController);
       emit EmergencyControllerSet(_emergencyController);
   }

   /**
    * @notice Deposit for a user (only callable by vault)
    */
   function depositFor(address user, uint256 amount) external onlyRole(VAULT_ROLE) whenNotPaused nonReentrant {
       require(user != address(0), "Silo: cannot deposit to zero");
       require(amount > 0, "Silo: amount is zero");
       
       // Check emergency state
       if (address(emergencyController) != address(0)) {
           require(
               emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.DEPOSITS_PAUSED &&
               emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.FULL_PAUSE,
               "Silo: deposits paused"
           );
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }

       underlyingToken.safeTransferFrom(msg.sender, address(this), amount);
       
       userDeposits[user] += amount;
       state.totalDeposited += amount;
       state.totalPendingClaims += amount;
       state.lastActivityTimestamp = block.timestamp;
       
       _checkLiquidity();
       
       emit Deposited(user, amount);
   }

   /**
    * @notice Withdraw to a user (only callable by vault)
    */
   function withdrawTo(address user, uint256 amount) external onlyRole(VAULT_ROLE) whenNotPaused nonReentrant {
       require(user != address(0), "Silo: cannot withdraw to zero");
       require(amount > 0, "Silo: amount is zero");
       require(!config.claimsPaused, "Silo: claims are paused due to liquidity");
       require(userDeposits[user] >= amount, "Silo: insufficient user balance");
       
       // Check emergency state
       if (address(emergencyController) != address(0)) {
           require(
               emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.WITHDRAWALS_PAUSED &&
               emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.FULL_PAUSE,
               "Silo: withdrawals paused"
           );
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       
       uint256 siloBalance = underlyingToken.balanceOf(address(this));
       if (siloBalance < amount) {
           emit LiquidityAlert(siloBalance, amount);
           config.claimsPaused = true;
           revert("Silo: insufficient liquidity for claim");
       }

       userDeposits[user] -= amount;
       state.totalDeposited -= amount;
       state.totalPendingClaims -= amount;
       state.totalWithdrawn += amount;
       state.lastActivityTimestamp = block.timestamp;
       
       underlyingToken.safeTransfer(user, amount);
       
       _checkLiquidity();
       
       emit Withdrawn(user, amount);
   }
   
   /**
    * @notice Early withdraw with fee
    */
   function earlyWithdraw(uint256 amount) external whenNotPaused nonReentrant {
       require(config.earlyUnlockEnabled, "Silo: early unlock disabled");
       require(!config.claimsPaused, "Silo: claims are paused due to liquidity");
       require(amount > 0, "Silo: amount is zero");
       require(userDeposits[msg.sender] >= amount, "Silo: insufficient balance");
       
       // Check emergency state
       if (address(emergencyController) != address(0)) {
           require(
               emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.WITHDRAWALS_PAUSED &&
               emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.FULL_PAUSE,
               "Silo: withdrawals paused"
           );
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       
       // Check rate limits
       _validateRateLimit(amount);
       
       // Check flash loan protection
       _validateAgainstFlashLoans(amount);
       
       UD60x18 amountUD = safeWrap(amount);
       UD60x18 feeUD = safeWrap(config.unlockFee);
       UD60x18 basisPointsUD = safeWrap(10000);
       
       uint256 feeAmount = safeUnwrap(amountUD.mul(feeUD).div(basisPointsUD));
       uint256 amountAfterFee = amount - feeAmount;
       
       uint256 siloBalance = underlyingToken.balanceOf(address(this));
       if (siloBalance < amount) {
           emit LiquidityAlert(siloBalance, amount);
           config.claimsPaused = true;
           revert("Silo: insufficient liquidity for claim");
       }
       
       userDeposits[msg.sender] -= amount;
       state.totalDeposited -= amount;
       state.totalPendingClaims -= amount;
       state.totalWithdrawn += amountAfterFee;
       state.totalCollectedFees += feeAmount;
       state.lastActivityTimestamp = block.timestamp;
       
       if (feeAmount > 0 && config.feeCollector != address(0)) {
           underlyingToken.safeTransfer(config.feeCollector, feeAmount);
       }
       underlyingToken.safeTransfer(msg.sender, amountAfterFee);
       
       _checkLiquidity();
       
       emit EarlyWithdrawn(msg.sender, amount, feeAmount);
   }
   
   /**
    * @notice Check liquidity status and update claimsPaused flag
    */
   function _checkLiquidity() internal {        
       if (state.totalPendingClaims == 0) {
           if (config.claimsPaused) {
               config.claimsPaused = false;
               emit ClaimsPausedSet(false);
           }
           return;
       }
       
       uint256 siloBalance = underlyingToken.balanceOf(address(this));
       
       UD60x18 siloBalanceUD = safeWrap(siloBalance);
       UD60x18 pendingClaimsUD = safeWrap(state.totalPendingClaims);
       UD60x18 basisPointsUD = safeWrap(10000);
       
       uint256 liquidityRatio = safeUnwrap(
           siloBalanceUD.mul(basisPointsUD).div(pendingClaimsUD)
       );
       
       if (liquidityRatio < config.liquidityThreshold && !config.claimsPaused) {
           config.claimsPaused = true;
           emit ClaimsPausedSet(true);
           emit LiquidityAlert(siloBalance, state.totalPendingClaims);
       }
       else if (liquidityRatio >= config.liquidityThreshold && config.claimsPaused) {
           config.claimsPaused = false;
           emit ClaimsPausedSet(false);
       }
   }
   
   /**
    * @notice Validate withdrawal against rate limits
    */
   function _validateRateLimit(uint256 amount) internal {
       // Skip in recovery mode
       if (address(emergencyController) != address(0) && emergencyController.isRecoveryModeActive()) return;
       
       // Reset daily window if needed
       if (block.timestamp >= withdrawalLimit.windowStartTime + 1 days) {
           withdrawalLimit.currentAmount = 0;
           withdrawalLimit.windowStartTime = block.timestamp;
           emit DailyLimitReset(block.timestamp);
       }
       
       // Check against limit
       require(withdrawalLimit.currentAmount + amount <= withdrawalLimit.maxDailyAmount, 
               "Silo: daily withdrawal limit reached");
       
       // Update counter
       withdrawalLimit.currentAmount += amount;
   }
   
   /**
    * @notice Validate transaction size against flash loan protection
    */
   function _validateAgainstFlashLoans(uint256 amount) internal view {
       // Skip in recovery mode
       if (address(emergencyController) != address(0) && emergencyController.isRecoveryModeActive()) return;
       
       if (withdrawalLimit.maxTransactionPercentage > 0 && state.totalDeposited > 0) {

           UD60x18 totalDepositedUD = safeWrap(state.totalDeposited);
           UD60x18 maxPercentUD = safeWrap(withdrawalLimit.maxTransactionPercentage);
           UD60x18 hundredUD = safeWrap(100);
           
           uint256 maxAmount = safeUnwrap(
               totalDepositedUD.mul(maxPercentUD).div(hundredUD)
           );
           require(amount <= maxAmount, "Silo: transaction too large");
       }
   }

   /**
    * @notice Get the balance of a user
    */
   function balanceOf(address user) external view returns (uint256) {
       return userDeposits[user];
   }
   
   /**
    * @notice Get the total amount deposited
    */
   function getTotalDeposited() external view returns (uint256) {
       return state.totalDeposited;
   }
   
   /**
    * @notice Calculate early withdrawal fee
    */
   function calculateEarlyWithdrawalFee(uint256 amount) external view returns (uint256 feeAmount, uint256 netAmount) {
       UD60x18 amountUD = safeWrap(amount);
       UD60x18 feeUD = safeWrap(config.unlockFee);
       UD60x18 basisPointsUD = safeWrap(10000);
       
       feeAmount = safeUnwrap(amountUD.mul(feeUD).div(basisPointsUD));
       netAmount = amount - feeAmount;
       return (feeAmount, netAmount);
   }
   
   /**
    * @notice Get liquidity status
    */
   function getLiquidityStatus() external view returns (
       uint256 liquidity, 
       uint256 pendingClaims, 
       uint256 ratio,
       bool isPaused,
       IEmergencyController.EmergencyState emergencyState
   ) {
       uint256 siloBalance = underlyingToken.balanceOf(address(this));
       
       uint256 liquidityRatio;
       if (state.totalPendingClaims > 0) {
           UD60x18 siloBalanceUD = safeWrap(siloBalance);
           UD60x18 pendingClaimsUD = safeWrap(state.totalPendingClaims);
           UD60x18 basisPointsUD = safeWrap(10000);
           
           liquidityRatio = safeUnwrap(
               siloBalanceUD.mul(basisPointsUD).div(pendingClaimsUD)
           );
       } else {
           liquidityRatio = 10000; // 100% if no pending claims
       }
        
       IEmergencyController.EmergencyState eState = address(emergencyController) != address(0) ?
           emergencyController.getEmergencyState() : IEmergencyController.EmergencyState.NORMAL;
           
       return (siloBalance, state.totalPendingClaims, liquidityRatio, config.claimsPaused, eState);
   }

   // Admin functions
   
   function setClaimsPaused(bool paused) external onlyRole(ADMIN_ROLE) {
       if (address(emergencyController) != address(0)) {
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       config.claimsPaused = paused;
       emit ClaimsPausedSet(paused);
   }
   
   function setLiquidityThreshold(uint256 threshold) external onlyRole(ADMIN_ROLE) {
       if (address(emergencyController) != address(0)) {
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       require(threshold > 0 && threshold <= 10000, "Silo: invalid threshold");
       config.liquidityThreshold = threshold;
       emit LiquidityThresholdSet(threshold);
   }
   
   function setUnlockFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
       if (address(emergencyController) != address(0)) {
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       require(_fee <= 1000, "Silo: fee too high"); // Max 10%
       config.unlockFee = _fee;
       emit UnlockFeeSet(_fee);
   }
   
   function setEarlyUnlockEnabled(bool _enabled) external onlyRole(ADMIN_ROLE) {
       if (address(emergencyController) != address(0)) {
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       config.earlyUnlockEnabled = _enabled;
       emit EarlyUnlockEnabledSet(_enabled);
   }
   
   function setFeeCollector(address _collector) external onlyRole(ADMIN_ROLE) {
       if (address(emergencyController) != address(0)) {
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       require(_collector != address(0), "Silo: zero address");
       config.feeCollector = _collector;
       emit FeeCollectorSet(_collector);
   }
   
   function adjustPendingClaims(uint256 newTotalPendingClaims) external onlyRole(ADMIN_ROLE) {
       state.totalPendingClaims = newTotalPendingClaims;
       _checkLiquidity();
   }
   
   function setRateLimit(uint256 _maxDailyWithdrawalAmount) external onlyRole(ADMIN_ROLE) {
       if (address(emergencyController) != address(0)) {
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       withdrawalLimit.maxDailyAmount = _maxDailyWithdrawalAmount;
       emit RateLimitUpdated(_maxDailyWithdrawalAmount);
   }
   
   function resetDailyLimit() external onlyRole(ADMIN_ROLE) {
       withdrawalLimit.currentAmount = 0;
       withdrawalLimit.windowStartTime = block.timestamp;
       emit DailyLimitReset(block.timestamp);
   }
   
   function setFlashLoanProtection(uint256 _maxTransactionPercentage) external onlyRole(ADMIN_ROLE) {
       if (address(emergencyController) != address(0)) {
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       require(_maxTransactionPercentage <= 50, "Silo: percentage too high");
       withdrawalLimit.maxTransactionPercentage = _maxTransactionPercentage;
   }
   
   function pause() external onlyRole(ADMIN_ROLE) {
       _pause();
   }
   
   function unpause() external onlyRole(ADMIN_ROLE) {
       if (address(emergencyController) != address(0)) {
           require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
       }
       _unpause();
   }

   function rescueTokens(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
       require(to != address(0), "Silo: zero address");
       require(amount > 0, "Silo: zero amount");
       
       if (token == address(underlyingToken)) {
           require(amount <= underlyingToken.balanceOf(address(this)), "Silo: insufficient balance");
           state.totalDeposited = state.totalDeposited > amount ? state.totalDeposited - amount : 0;
           state.totalPendingClaims = state.totalPendingClaims > amount ? state.totalPendingClaims - amount : 0;
           _checkLiquidity();
       }
       
       IERC20Upgradeable(token).safeTransfer(to, amount);
       emit RescuedTokens(token, to, amount);
   }

   /**
    * @notice Set vault address and grant VAULT_ROLE
    * @param _vault The vault address to set
    */
    function setVault(address _vault) external onlyRole(ADMIN_ROLE) {
        require(_vault != address(0), "Silo: invalid vault");
        _grantRole(VAULT_ROLE, _vault);
    }
   
   function updateVersion(string memory _newVersion) external onlyRole(ADMIN_ROLE) {
       upgradeControl.version = _newVersion;
       emit VersionUpdated(_newVersion);
   }
   
   function requestUpgrade() external onlyRole(ADMIN_ROLE) {
       if (upgradeControl.requested) {
           require(block.timestamp >= upgradeControl.requestTime + UPGRADE_TIMELOCK, 
               "Previous upgrade request still in timelock period");
       }
       upgradeControl.requestTime = block.timestamp;
       upgradeControl.requested = true;
       emit UpgradeRequested(upgradeControl.requestTime);
   }

   function cancelUpgrade() external onlyRole(ADMIN_ROLE) {
       require(upgradeControl.requested, "No upgrade to cancel");
       upgradeControl.requested = false;
       emit UpgradeCancelled(upgradeControl.requestTime);
       upgradeControl.requestTime = 0;
   }
   
   function upgradeRequested() external view returns (bool requested, uint256 requestTime) {
       return (upgradeControl.requested, upgradeControl.requestTime);
   }
   
   function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
       require(newImplementation != address(0), "Silo: invalid implementation");
       require(upgradeControl.requested, "Silo: upgrade not requested");
       require(block.timestamp >= upgradeControl.requestTime + UPGRADE_TIMELOCK, "Silo: timelock not expired");
       
       upgradeControl.requested = false;
       emit UpgradeAuthorized(newImplementation, upgradeControl.version);
   }
   
   uint256[20] private __gap;
}