// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// External libraries and contracts
import { UD60x18, wrap, unwrap } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IEmergencyController.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
* @title TokenSilo
* @notice A temporary holding contract for underlying tokens during the unstaking cooldown period.
* It ensures that funds designated for withdrawal are segregated from the main vault's liquidity.
* @dev This contract receives funds from the UnstakeManager and holds them until a user claims them
* after the cooldown or withdraws them early (if enabled).
*/
contract TokenSilo is
Initializable,
AccessControlUpgradeable,
ReentrancyGuardUpgradeable,
PausableUpgradeable,
UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    // --- Roles ---
    /// @notice The VAULT_ROLE is granted to contracts that are allowed to deposit into and withdraw from the silo.
    /// @dev This is typically the UnstakeManager, which moves funds on behalf of users.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    // --- State Variables ---
    IERC20Upgradeable public underlyingToken;
    string public tokenSymbol;
    IEmergencyController public emergencyController;
    /// @notice Tracks the amount of underlying tokens each user has waiting in the silo.
    mapping(address => uint256) public userDeposits;
    /// @notice Aggregates the overall state of the silo for accounting and health checks.
    struct SiloState {
        uint256 totalWithdrawn; // Total amount ever withdrawn (regular + early).
        uint256 totalPendingClaims; // Total amount currently held in the silo waiting for user claims.
        uint256 totalCollectedFees;
        // Total fees collected from early withdrawals.
        uint256 lastActivityTimestamp; // Timestamp of the last deposit or withdrawal.
    }
    SiloState public state;

    /// @notice Configuration for the early withdrawal feature.
    struct CooldownConfig {
        uint256 unlockFee;
        // The fee (in basis points) for early withdrawal.
        bool earlyUnlockEnabled; // Flag to enable/disable the early withdrawal feature.
        address feeCollector; // The address that receives early withdrawal fees.
        bool claimsPaused;
        // A flag automatically triggered if liquidity drops below the threshold.
        uint256 liquidityThreshold;
        // The minimum liquidity ratio (balance / pending claims) required.
    }
    CooldownConfig public config;
    /// @notice Configuration for withdrawal rate limiting.
    struct RateLimit {
        uint256 maxDailyAmount;
        // Max total amount that can be withdrawn in a 24h period.
        uint256 currentAmount;
        // The amount withdrawn in the current 24h window.
        uint256 windowStartTime; // Start time of the current 24h window.
    }
    RateLimit public withdrawalLimit;
    // --- Upgrade Control ---
    struct UpgradeControl {
        uint256 version;
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

    // --- Events ---
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
     * @notice Initializes the silo contract with its core parameters.
     * @dev Called by the VaultFactory during deployment.
    * @param _underlyingToken The underlying token address.
    * @param _tokenSymbol The token symbol.
    * @param vault The address that will be granted VAULT_ROLE (typically the UnstakeManager).
     */
    function initialize(
        address _underlyingToken,
        string memory _tokenSymbol,
        address vault,
        address _feeCollector
    ) public initializer {
        require(_underlyingToken != address(0), "Silo: invalid underlying token");
        require(vault != address(0), "Silo: invalid vault");

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

        config.unlockFee = 50; // 0.5% in basis points
        config.earlyUnlockEnabled = false;
        require(_feeCollector != address(0), "Silo: invalid fee collector");
        config.feeCollector = _feeCollector;
        config.claimsPaused = false;
        config.liquidityThreshold = 8000; // 80%

        uint8 _underlyingDecimals = IERC20MetadataUpgradeable(_underlyingToken).decimals();
        withdrawalLimit.maxDailyAmount = 50_000 * (10**_underlyingDecimals);
        withdrawalLimit.windowStartTime = block.timestamp;

        upgradeControl.version = 1;
    }

    /**
     * @notice Sets the address of the global EmergencyController.
     */
    function setEmergencyController(address _emergencyController) external onlyRole(ADMIN_ROLE) {
        require(_emergencyController != address(0), "Silo: invalid controller");
        emergencyController = IEmergencyController(_emergencyController);
        emit EmergencyControllerSet(_emergencyController);
    }

    /**
     * @notice Receives funds from the UnstakeManager for a user who has processed an unstake request.
     * @dev This function is protected by `VAULT_ROLE`.
    * @param user The end user for whom the funds are being deposited.
    * @param amount The amount of underlying tokens to deposit.
     */
    function depositFor(address user, uint256 amount) external onlyRole(VAULT_ROLE) whenNotPaused nonReentrant {
        require(user != address(0), "Silo: cannot deposit to zero");
        require(amount > 0, "Silo: amount is zero");

        if (address(emergencyController) != address(0)) {
            require(
                emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.WITHDRAWALS_PAUSED &&
                emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.FULL_PAUSE,
                "Silo: deposits paused"
            );
            require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
        }

        underlyingToken.safeTransferFrom(msg.sender, address(this), amount);

        userDeposits[user] += amount;
        state.totalPendingClaims += amount;
        state.lastActivityTimestamp = block.timestamp;

        _checkLiquidity();

        emit Deposited(user, amount);
    }

    /**
     * @notice Sends funds to a user who is claiming their unstaked tokens after the cooldown period.
     * @dev This function is protected by `VAULT_ROLE` and is called by the UnstakeManager.
    * @param user The user who is claiming their funds.
    * @param amount The amount of underlying tokens to withdraw.
     */
    function withdrawTo(address user, uint256 amount) external onlyRole(VAULT_ROLE) whenNotPaused nonReentrant {
        require(user != address(0), "Silo: cannot withdraw to zero");
        require(amount > 0, "Silo: amount is zero");
        require(!config.claimsPaused, "Silo: claims are paused due to liquidity");
        require(userDeposits[user] >= amount, "Silo: insufficient user balance");

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
            revert("Silo: insufficient liquidity for claim");
        }

        userDeposits[user] -= amount;
        state.totalPendingClaims -= amount;
        state.totalWithdrawn += amount;
        state.lastActivityTimestamp = block.timestamp;

        underlyingToken.safeTransfer(user, amount);

        _checkLiquidity();

        emit Withdrawn(user, amount);
    }

    /**
     * @notice Allows a user to withdraw their funds from the silo before the cooldown period ends, for a fee.
     * @dev This function is subject to rate limiting.
    * @param amount The amount the user wishes to withdraw early.
    * @param user The user who on behalf the call is called
     */
    function earlyWithdrawFor(address user, uint256 amount) external onlyRole(VAULT_ROLE) whenNotPaused nonReentrant {
        require(config.earlyUnlockEnabled, "Silo: early unlock disabled");
        require(!config.claimsPaused, "Silo: claims are paused due to liquidity");
        require(amount > 0, "Silo: amount is zero");
        require(userDeposits[user] >= amount, "Silo: insufficient balance");

        if (address(emergencyController) != address(0)) {
            require(
                emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.WITHDRAWALS_PAUSED &&
                emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.FULL_PAUSE,
                "Silo: withdrawals paused"
            );
            require(!emergencyController.isRecoveryModeActive(), "Silo: recovery mode active");
        }

        _validateRateLimit(amount);

        UD60x18 amountUD = safeWrap(amount);
        UD60x18 feeUD = safeWrap(config.unlockFee);
        UD60x18 basisPointsUD = safeWrap(10000);

        uint256 feeAmount = safeUnwrap(amountUD.mul(feeUD).div(basisPointsUD));
        uint256 amountAfterFee = amount - feeAmount;
        uint256 siloBalance = underlyingToken.balanceOf(address(this));
        if (siloBalance < amount) {
            emit LiquidityAlert(siloBalance, amount);
            revert("Silo: insufficient liquidity for claim");
        }

        userDeposits[user] -= amount;
        state.totalPendingClaims -= amount;
        state.totalWithdrawn += amountAfterFee;
        state.totalCollectedFees += feeAmount;
        state.lastActivityTimestamp = block.timestamp;
        if (feeAmount > 0 && config.feeCollector != address(0)) {
            underlyingToken.safeTransfer(config.feeCollector, feeAmount);
        }
        underlyingToken.safeTransfer(user, amountAfterFee);

        _checkLiquidity();

        emit EarlyWithdrawn(user, amount, feeAmount);
    }

    /**
     * @notice Internal function to check if the silo has enough funds to cover all pending claims.
     * @dev If the ratio of `balance / totalPendingClaims` falls below `liquidityThreshold`, it automatically
    * pauses all claims to prevent a bank run on an under-funded silo.
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
     * @notice Internal function to validate a withdrawal against daily rate limits.
     */
    function _validateRateLimit(uint256 amount) internal {
        if (address(emergencyController) != address(0) && emergencyController.isRecoveryModeActive()) return;
        if (block.timestamp >= withdrawalLimit.windowStartTime + 1 days) {
            withdrawalLimit.currentAmount = 0;
            withdrawalLimit.windowStartTime = block.timestamp;
            emit DailyLimitReset(block.timestamp);
        }

        require(withdrawalLimit.currentAmount + amount <= withdrawalLimit.maxDailyAmount,
            "Silo: daily withdrawal limit reached");
        withdrawalLimit.currentAmount += amount;
    }

    /**
     * @notice Gets the amount of underlying tokens a specific user has in the silo.
     */
    function balanceOf(address user) external view returns (uint256) {
        return userDeposits[user];
    }

    /**
     * @notice Gets the total amount of underlying tokens currently held in the silo for all users.
     */
    function getTotalDeposited() external view returns (uint256) {
        return state.totalPendingClaims;
    }

    /**
     * @notice A view function to calculate the fee for an early withdrawal without executing it.
    * @param amount The amount to calculate the fee for.
    * @return feeAmount The calculated fee.
    * @return netAmount The amount the user would receive after the fee.
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
     * @notice A view function that returns a comprehensive status of the silo's liquidity.
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
            liquidityRatio = 10000;
            // 100% if no pending claims
        }

        IEmergencyController.EmergencyState eState = address(emergencyController) != address(0) ?
            emergencyController.getEmergencyState() : IEmergencyController.EmergencyState.NORMAL;

        return (siloBalance, state.totalPendingClaims, liquidityRatio, config.claimsPaused, eState);
    }

    // --- Admin functions ---

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
        require(_fee <= 1000, "Silo: fee too high");
        // Max 10%
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
            state.totalPendingClaims = state.totalPendingClaims > amount ? state.totalPendingClaims - amount : 0;
            _checkLiquidity();
        }

        IERC20Upgradeable(token).safeTransfer(to, amount);
        emit RescuedTokens(token, to, amount);
    }

    function setVault(address _vault) external onlyRole(ADMIN_ROLE) {
        require(_vault != address(0), "Silo: invalid vault");
        _grantRole(VAULT_ROLE, _vault);
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

        uint256 oldVersion = upgradeControl.version;
        upgradeControl.version++;

        emit UpgradeAuthorized(newImplementation, Strings.toString(oldVersion));
    }

    uint256[41] private __gap;
}