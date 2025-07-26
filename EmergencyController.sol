// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IEmergencyController.sol";

/**
 * @title EmergencyController
 * @notice Centralized emergency control module for the LST system
 */
contract EmergencyController is 
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IEmergencyController
{
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // Emergency state
    EmergencyState private _emergencyState;
    
    // Recovery mode
    bool public recoveryModeActive;
    uint256 public recoveryModeActivationTime;
    uint256 public constant RECOVERY_DELAY = 24 hours;
    
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
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the Emergency Controller
     * @param _admin Initial admin address
     */
    function initialize(address _admin) external initializer {
        require(_admin != address(0), "EmergencyController: invalid admin");
        
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        
        // Initialize state
        _emergencyState = EmergencyState.NORMAL;
        recoveryModeActive = false;
        
        version = "1.0.0";
    }
    
    function getEmergencyState() external view override returns (EmergencyState) {
        return _emergencyState;
    }
    
    function isRecoveryModeActive() external view override returns (bool) {
        return recoveryModeActive;
    }
    
    function setEmergencyState(EmergencyState _state) external override onlyRole(EMERGENCY_ROLE) {
        _emergencyState = _state;
        emit EmergencyStateChanged(_state);
    }
    
    function pauseDeposits() external override onlyRole(EMERGENCY_ROLE) {
        _emergencyState = EmergencyState.DEPOSITS_PAUSED;
        emit EmergencyStateChanged(EmergencyState.DEPOSITS_PAUSED);
    }
    
    function pauseWithdrawals() external override onlyRole(EMERGENCY_ROLE) {
        _emergencyState = EmergencyState.WITHDRAWALS_PAUSED;
        emit EmergencyStateChanged(EmergencyState.WITHDRAWALS_PAUSED);
    }
    
    function pauseAll() external override onlyRole(EMERGENCY_ROLE) {
        _emergencyState = EmergencyState.FULL_PAUSE;
        emit EmergencyStateChanged(EmergencyState.FULL_PAUSE);
    }
    
    function resumeOperations() external override onlyRole(ADMIN_ROLE) {
        require(!recoveryModeActive, "EmergencyController: recovery mode active");
        _emergencyState = EmergencyState.NORMAL;
        emit EmergencyStateChanged(EmergencyState.NORMAL);
    }
    
    function triggerCircuitBreaker(string calldata reason) external override onlyRole(EMERGENCY_ROLE) {
        _emergencyState = EmergencyState.FULL_PAUSE;
        emit EmergencyStateChanged(EmergencyState.FULL_PAUSE);
        
        recoveryModeActivationTime = block.timestamp;
        emit RecoveryModeScheduled(recoveryModeActivationTime);
        
        emit EmergencyCircuitBreakerTriggered(block.timestamp, reason);
    }
    
    function scheduleRecoveryMode() external override onlyRole(EMERGENCY_ROLE) {
        require(!recoveryModeActive, "EmergencyController: recovery already active");
        
        recoveryModeActivationTime = block.timestamp;
        emit RecoveryModeScheduled(recoveryModeActivationTime);
    }
    
    function activateRecoveryMode() external override onlyRole(EMERGENCY_ROLE) {
        require(recoveryModeActivationTime > 0, "EmergencyController: recovery not scheduled");
        require(
            block.timestamp >= recoveryModeActivationTime + RECOVERY_DELAY,
            "EmergencyController: timelock not expired"
        );
        require(!recoveryModeActive, "EmergencyController: recovery already active");
        
        recoveryModeActive = true;
        emit RecoveryModeActivated(block.timestamp);
        
        _emergencyState = EmergencyState.FULL_PAUSE;
        emit EmergencyStateChanged(EmergencyState.FULL_PAUSE);
    }
    
    function deactivateRecoveryMode() external override onlyRole(ADMIN_ROLE) {
        require(recoveryModeActive, "EmergencyController: recovery not active");
        
        recoveryModeActive = false;
        recoveryModeActivationTime = 0;
        emit RecoveryModeDeactivated(block.timestamp);
    }

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

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        require(newImplementation != address(0), "EmergencyController: invalid implementation");
        require(upgradeRequested, "EmergencyController: upgrade not requested");
        require(block.timestamp >= upgradeRequestTime + UPGRADE_TIMELOCK, "EmergencyController: timelock not expired");
        
        upgradeRequested = false;
        
        emit UpgradeAuthorized(newImplementation, version);
    }
    
    function updateVersion(string memory _newVersion) external onlyRole(ADMIN_ROLE) {
        version = _newVersion;
        emit VersionUpdated(_newVersion);
    }
    
    uint256[40] private __gap;
}