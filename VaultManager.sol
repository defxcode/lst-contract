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
import "./interfaces/ILSTokenVault.sol";

/**
 * @title VaultManager
 * @notice A stateless administrative control module for an LSTokenVault.
 * @dev This contract is the single point of entry for admins to change parameters. It holds no funds
 * or configuration state itself, but is granted a MANAGER_ROLE on the LSTokenVault to execute commands.
 */
contract VaultManager is
Initializable,
AccessControlUpgradeable,
ReentrancyGuardUpgradeable,
UUPSUpgradeable,
IVaultManager
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // --- Constants ---
    uint256 public constant MAX_FEE_PERCENT = 30;

    // --- State Variables ---
    address public vault;
    IEmergencyController public emergencyController;
    IUnstakeManager public unstakeManager;

    // --- Version and upgrade controls ---
    string public version;
    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    uint256 public upgradeRequestTime;
    bool public upgradeRequested;

    // --- Events ---
    event VersionUpdated(string newVersion);
    event UpgradeRequested(uint256 requestTime);
    event UpgradeCancelled(uint256 requestTime);
    event UpgradeAuthorized(address indexed implementation, string currentVersion);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the admin module.
     */
    function initialize(address _vault, address _admin) external initializer {
        require(_vault != address(0), "VaultManager: invalid vault");
        require(_admin != address(0), "VaultManager: invalid admin");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        vault = _vault;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);

        version = "1.0.0";
    }

    // --- Contract Links Setup ---
    function setEmergencyController(address _emergencyController) external override onlyRole(ADMIN_ROLE) {
        require(_emergencyController != address(0), "VaultManager: invalid controller");
        emergencyController = IEmergencyController(_emergencyController);
        emit EmergencyControllerSet(_emergencyController);
    }

    function setUnstakeManager(address _unstakeManager) external override onlyRole(ADMIN_ROLE) {
        require(_unstakeManager != address(0), "VaultManager: invalid unstake manager");
        unstakeManager = IUnstakeManager(_unstakeManager);
        emit UnstakeManagerSet(_unstakeManager);
    }

    // --- Proxied Admin Functions ---

    function setCooldownPeriod(uint256 _cooldown) external override onlyRole(ADMIN_ROLE) {
        require(address(unstakeManager) != address(0), "VaultManager: unstake manager not set");
        IUnstakeManager(unstakeManager).setCooldownPeriod(_cooldown);
    }

    function setMinUnstakeAmount(uint256 _minUnstakeAmount) external override onlyRole(ADMIN_ROLE) {
        require(address(unstakeManager) != address(0), "VaultManager: unstake manager not set");
        IUnstakeManager(unstakeManager).setMinUnstakeAmount(_minUnstakeAmount);
    }

    function setMaxTotalDeposit(uint256 _maxTotalDeposit) external override onlyRole(ADMIN_ROLE) {
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).setMaxTotalDeposit(_maxTotalDeposit);
    }

    function setMaxUserDeposit(uint256 _maxUserDeposit) external override onlyRole(ADMIN_ROLE) {
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).setMaxUserDeposit(_maxUserDeposit);
    }

    function setFeePercent(uint256 _feePercent) external override onlyRole(ADMIN_ROLE) {
        require(_feePercent <= MAX_FEE_PERCENT, "VaultManager: fee too high");
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).setFeePercent(_feePercent);
    }

    function setFeeReceiver(address _feeReceiver) external override onlyRole(ADMIN_ROLE) {
        require(_feeReceiver != address(0), "VaultManager: invalid fee receiver");
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).setFeeReceiver(_feeReceiver);
    }

    function setStakeEnabled(bool _enabled) external override onlyRole(ADMIN_ROLE) {
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).setStakeEnabled(_enabled);
    }

    function setUnstakeEnabled(bool _enabled) external override onlyRole(ADMIN_ROLE) {
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).setUnstakeEnabled(_enabled);
    }

    function withdrawFees() external override onlyRole(MANAGER_ROLE) {
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).withdrawFees();
    }

    function transferCollateral(address to, uint256 amount) external override onlyRole(ADMIN_ROLE) {
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).transferUnderlying(to, amount);
        emit AdminTransfer(to, amount);
    }

    /**
     * @notice Sets the float percentage for the associated vault.
     * @dev Calls the corresponding function on LSTokenVault.
     */
    function setFloatPercent(uint256 _floatPercent) external onlyRole(ADMIN_ROLE) {
        require(vault != address(0), "VaultManager: vault not set");
        ILSTokenVault(vault).setFloatPercent(_floatPercent);
    }

    // --- Upgrade Functions ---
    function requestUpgrade() external onlyRole(ADMIN_ROLE) {
        if (upgradeRequested) {
            require(block.timestamp >= upgradeRequestTime + UPGRADE_TIMELOCK, "Previous upgrade request still in timelock period");
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

    uint256[20] private __gap;
}