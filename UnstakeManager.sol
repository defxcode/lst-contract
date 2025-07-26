// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { UD60x18, wrap, unwrap } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "./interfaces/ILSToken.sol";
import "./interfaces/ITokenSilo.sol";
import "./interfaces/IUnstakeManager.sol";
import "./interfaces/IEmergencyController.sol";
import "./interfaces/ILSTokenVault.sol";

/**
* @title UnstakeManager
* @notice Handles unstaking requests
*/
contract UnstakeManager is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IUnstakeManager
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    
    // Roles
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // Core contracts
    address public vault;
    IERC20Upgradeable public underlyingToken;
    ILSToken public lsToken;
    ITokenSilo public silo;
    IEmergencyController public emergencyController;
    
    // Token metadata
    string public underlyingSymbol;
    string public lsTokenSymbol;
    
    // Unstake request struct
    struct UnstakeRequest {
        uint256 lsTokenAmount;
        uint256 requestTimestamp;
        uint256 underlyingAmount;
        RequestStatus status;
        uint256 requestId;
    }

    // Configuration
    uint256 public cooldownPeriod;
    uint256 public maxCooldownPeriod;
    uint256 public minUnstakeAmount;
    
    // Unified queue management
    uint256 private nextRequestId;
    mapping(address => UnstakeRequest) public unstakeRequests;
    mapping(uint256 => address) public requestIdToAddress;
    
    // Single unified queue
    uint256[] public queuedRequestIds;
    
    // Queue metrics
    uint256 public queueLength;
    uint256 public totalQueuedUnstakeAmount;
    
    // Auto-cleanup tracking
    uint256 private processedRequestCounter;
    uint256 private lastCleanupCounter;
    uint256 private constant CLEANUP_INTERVAL = 50;
    uint256 private constant CLEANUP_BATCH_SIZE = 5;
    
    // Version and upgrade controls
    string public version;
    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    uint256 public upgradeRequestTime;
    bool public upgradeRequested;
    
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
    event VersionUpdated(string newVersion);
    event UpgradeRequested(uint256 requestTime);
    event UpgradeCancelled(uint256 requestTime);
    event UpgradeAuthorized(address indexed implementation, string currentVersion);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Unstake Manager
     */
    function initialize(
        address _vault, 
        address _underlyingToken, 
        address _lsToken, 
        address _silo
    ) external initializer {
        require(_vault != address(0), "UnstakeManager: invalid vault");
        require(_underlyingToken != address(0), "UnstakeManager: invalid underlying token");
        require(_lsToken != address(0), "UnstakeManager: invalid LS token");
        require(_silo != address(0), "UnstakeManager: invalid silo");
        
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        vault = _vault;
        underlyingToken = IERC20Upgradeable(_underlyingToken);
        lsToken = ILSToken(_lsToken);
        silo = ITokenSilo(_silo);
        
        // Set token symbols
        underlyingSymbol = _getTokenSymbol(_underlyingToken);
        lsTokenSymbol = _getTokenSymbol(_lsToken);
        
        // Initialize queue parameters
        nextRequestId = 1;
        processedRequestCounter = 0;
        lastCleanupCounter = 0;
        
        // Set default configuration
        cooldownPeriod = 7 days;
        maxCooldownPeriod = 30 days;
        minUnstakeAmount = 0.1 ether; // 0.1 LS token
        
        // Set roles - grant VAULT_ROLE to the vault
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(VAULT_ROLE, _vault);
        _grantRole(MANAGER_ROLE, msg.sender);
        
        // Validate vault role was granted
        require(hasRole(VAULT_ROLE, _vault), "UnstakeManager: vault role not granted");
        
        version = "1.0.0";
    }
    
    /**
     * @notice Get token symbol safely
     */
    function _getTokenSymbol(address token) internal view returns (string memory) {
        try IERC20MetadataUpgradeable(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "UNKNOWN";
        }
    }

    /**
     * @notice Transfer underlying tokens from vault to this contract for processing
     */
    function _transferFromVault(uint256 amount) internal {
        require(underlyingToken.balanceOf(vault) >= amount, "UnstakeManager: insufficient vault balance");
        underlyingToken.safeTransferFrom(vault, address(this), amount);
    }
    
    /**
     * @notice Set the emergency controller
     */
    function setEmergencyController(address _emergencyController) external onlyRole(ADMIN_ROLE) {
        require(_emergencyController != address(0), "UnstakeManager: invalid controller");
        emergencyController = IEmergencyController(_emergencyController);
        emit EmergencyControllerSet(_emergencyController);
    }
    
    /**
     * @notice Set cooldown period
     */
    function setCooldownPeriod(uint256 _period) external onlyRole(ADMIN_ROLE) {
        require(_period > 0 && _period <= maxCooldownPeriod, "UnstakeManager: invalid period");
        cooldownPeriod = _period;
        emit CooldownPeriodSet(_period);
    }
    
    /**
     * @notice Set minimum unstake amount
     */
    function setMinUnstakeAmount(uint256 _amount) external onlyRole(ADMIN_ROLE) {
        require(_amount > 0, "UnstakeManager: amount must be > 0");
        minUnstakeAmount = _amount;
        emit MinUnstakeAmountSet(_amount);
    }

    /**
     * @notice Request to unstake LS tokens
     */
    function requestUnstake(
        address user, 
        uint256 lsTokenAmount, 
        uint256 minUnderlyingAmount, 
        uint256 currentIndex
    ) external override onlyRole(VAULT_ROLE) {
        require(lsTokenAmount >= minUnstakeAmount, "UnstakeManager: below min unstake amount");
        require(user != address(0), "UnstakeManager: invalid user address");
        require(unstakeRequests[user].lsTokenAmount == 0, "UnstakeManager: active unstake pending");

        // Burn LS tokens
        lsToken.burnFrom(user, lsTokenAmount);

        // Calculate underlying amount using provided index
        UD60x18 lsTokenUD = safeWrap(lsTokenAmount);
        UD60x18 currentIndexUD = safeWrap(currentIndex);
        UD60x18 precisionUD = safeWrap(1e18);
        
        uint256 underlyingAmount = safeUnwrap(
            lsTokenUD.mul(currentIndexUD).div(precisionUD)
        );
        
        // Optional slippage check
        if (minUnderlyingAmount > 0) {
            require(underlyingAmount >= minUnderlyingAmount, "UnstakeManager: slippage too high");
        }
        require(underlyingAmount > 0, "UnstakeManager: underlying amount is 0");

        // Generate unique request ID
        uint256 requestId = nextRequestId++;
        
        // Record unstake request
        unstakeRequests[user] = UnstakeRequest({
            lsTokenAmount: lsTokenAmount,
            requestTimestamp: block.timestamp,
            underlyingAmount: underlyingAmount,
            status: RequestStatus.QUEUED,
            requestId: requestId
        });
        
        // Map request ID to user address for quick lookup
        requestIdToAddress[requestId] = user;
        
        // Add to queue
        queuedRequestIds.push(requestId);
        
        // Update queue metrics
        queueLength++;
        totalQueuedUnstakeAmount += underlyingAmount;
        
        emit UnstakeRequested(user, lsTokenAmount, block.timestamp + cooldownPeriod, requestId);
        emit UnstakeStatusChanged(user, RequestStatus.QUEUED, requestId);
    }
    
    /**
     * @notice Mark specific requests for processing
     */
    function markRequestsForProcessing(uint256[] calldata requestIds) 
        external 
        override 
        onlyRole(MANAGER_ROLE) 
        nonReentrant 
        returns (uint256 processedCount) 
    {
        require(requestIds.length > 0, "UnstakeManager: empty request list");
        
        uint256 count = 0;
        
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];
            address user = requestIdToAddress[requestId];
            
            // Validate request
            if (user == address(0)) continue;
            
            UnstakeRequest storage request = unstakeRequests[user];
            
            // Check if request is valid and queued
            if (request.status != RequestStatus.QUEUED || request.requestId != requestId) continue;
            
            // Update request status
            request.status = RequestStatus.PROCESSING;
            
            count++;
            emit UnstakeStatusChanged(user, RequestStatus.PROCESSING, requestId);
        }
        
        return count;
    }
    
    /**
     * @notice Remove a request from the queue
     */
    function _removeFromQueue(uint256 requestId) private {
        // Find index of request ID in queuedRequestIds
        for (uint256 i = 0; i < queuedRequestIds.length; i++) {
            if (queuedRequestIds[i] == requestId) {
                // Swap with last element and pop (gas efficient removal)
                if (i < queuedRequestIds.length - 1) {
                    queuedRequestIds[i] = queuedRequestIds[queuedRequestIds.length - 1];
                }
                queuedRequestIds.pop();
                break;
            }
        }
    }
    
    /**
     * @notice Process unstake requests in batch
     */
    function processUnstakeQueue(uint256 batchSize) 
        external 
        override 
        onlyRole(MANAGER_ROLE) 
        nonReentrant 
        returns (uint256 processed, uint256 remaining) 
    {
        require(address(silo) != address(0), "UnstakeManager: silo not set");
        require(address(emergencyController) != address(0), "UnstakeManager: emergency controller not set");
        require(
            emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.FULL_PAUSE,
            "UnstakeManager: system fully paused"
        );
        
        uint256 vaultBalance = underlyingToken.balanceOf(vault);
        uint256 successCount = 0;
        uint256 totalAmountToProcess = 0;
        
        // Create batch of requests to process
        address[] memory usersToProcess = new address[](batchSize);
        uint256[] memory requestIdsToProcess = new uint256[](batchSize);
        uint256[] memory amountsToProcess = new uint256[](batchSize);
        
        uint256 batchIndex = 0;
        
        // Create batch of requests that can be processed
        for (uint256 i = 0; i < queuedRequestIds.length && batchIndex < batchSize; i++) {
            uint256 requestId = queuedRequestIds[i];
            address user = requestIdToAddress[requestId];
            
            if (user == address(0)) continue;
            
            UnstakeRequest storage request = unstakeRequests[user];
            
            // Only process requests in PROCESSING status
            if (request.status != RequestStatus.PROCESSING || request.requestId != requestId) continue;
            
            // Check if we have enough balance to process this request
            if (totalAmountToProcess + request.underlyingAmount <= vaultBalance) {
                usersToProcess[batchIndex] = user;
                requestIdsToProcess[batchIndex] = requestId;
                amountsToProcess[batchIndex] = request.underlyingAmount;
                totalAmountToProcess += request.underlyingAmount;
                batchIndex++;
            }
        }
        
        // If we have items to process, get underlying tokens from vault and process
        if (batchIndex > 0 && totalAmountToProcess > 0) {
            // Transfer from vault first
            _transferFromVault(totalAmountToProcess);
            
            // Set exact allowance once for all transfers
            underlyingToken.safeApprove(address(silo), 0);
            underlyingToken.safeApprove(address(silo), totalAmountToProcess);
            
            // Process each request individually
            for (uint256 i = 0; i < batchIndex; i++) {
                address user = usersToProcess[i];
                uint256 requestId = requestIdsToProcess[i];
                uint256 amount = amountsToProcess[i];
                
                // Skip invalid entries
                if (user == address(0) || amount == 0) continue;
                
                try silo.depositFor(user, amount) {
                    // Update state AFTER successful external call
                    unstakeRequests[user].status = RequestStatus.PROCESSED;
                    
                    // Remove from queue
                    _removeFromQueue(requestId);
                    
                    // Update queue metrics
                    queueLength--;
                    totalQueuedUnstakeAmount -= amount;
                    
                    successCount++;
                    emit UnstakeProcessed(user, amount, requestId);
                    emit UnstakeStatusChanged(user, RequestStatus.PROCESSED, requestId);
                } catch {
                    // If the external call fails, leave the request state unchanged
                    emit UnstakeProcessingFailed(user, amount, requestId);
                }
            }
        }
        
        return (successCount, queueLength);
    }
    
/**
 * @notice Process a specific user's unstake request directly from the queue.
 * @dev This function now transitions a request from QUEUED directly to PROCESSED,
 * bypassing the PROCESSING state to avoid conflicts with the batch processor.
 */
function processUserUnstake(address user) 
    external 
    override 
    onlyRole(MANAGER_ROLE) 
    nonReentrant 
    returns (bool processed) 
{
    require(address(silo) != address(0), "UnstakeManager: silo not set");
    require(user != address(0), "UnstakeManager: invalid user address");
    require(address(emergencyController) != address(0), "UnstakeManager: emergency controller not set");
    require(
        emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.FULL_PAUSE,
        "UnstakeManager: system fully paused"
    );
    
    UnstakeRequest storage request = unstakeRequests[user];
    
    require(request.status == RequestStatus.QUEUED, "UnstakeManager: request not in queue or already processing");
    
    uint256 underlyingAmount = request.underlyingAmount;
    uint256 requestId = request.requestId;

    require(underlyingToken.balanceOf(vault) >= underlyingAmount, "UnstakeManager: insufficient vault balance");
    
    // Optimistically set status to PROCESSED. The entire transaction will revert if any step below fails.
    request.status = RequestStatus.PROCESSED;
    emit UnstakeStatusChanged(user, RequestStatus.PROCESSED, requestId);

    // Transfer from vault
    _transferFromVault(underlyingAmount);
    
    // Approve the Silo to spend the tokens we just received
    underlyingToken.safeApprove(address(silo), 0);
    underlyingToken.safeApprove(address(silo), underlyingAmount);
    
    silo.depositFor(user, underlyingAmount);
    
    // Clean up the queue and metrics
    _removeFromQueue(requestId);
    queueLength--;
    totalQueuedUnstakeAmount -= underlyingAmount;
    
    emit UnstakeProcessed(user, underlyingAmount, requestId);
    
    return true;
}
    
    /**
     * @notice Claim underlying tokens after cooldown period
     */
    function claim(address user) external override nonReentrant {
        require(msg.sender == vault || msg.sender == user, "UnstakeManager: not authorized");
        
        require(address(emergencyController) != address(0), "UnstakeManager: emergency controller not set");
        
        // Check emergency state
        require(
            emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.WITHDRAWALS_PAUSED &&
            emergencyController.getEmergencyState() != IEmergencyController.EmergencyState.FULL_PAUSE,
            "UnstakeManager: withdrawals paused"
        );
        require(!emergencyController.isRecoveryModeActive(), "UnstakeManager: recovery mode active");
        
        UnstakeRequest storage request = unstakeRequests[user];
        require(request.lsTokenAmount > 0, "UnstakeManager: no pending unstake");
        require(request.status == RequestStatus.PROCESSED, "UnstakeManager: unstake not processed yet");
        require(block.timestamp >= request.requestTimestamp + cooldownPeriod, "UnstakeManager: cooldown not finished");

        uint256 underlyingAmount = request.underlyingAmount;
        uint256 requestId = request.requestId;
        require(underlyingAmount > 0, "UnstakeManager: calculated underlying amount is 0");

        // Clear request before external calls
        delete unstakeRequests[user];
        delete requestIdToAddress[requestId];
        _removeFromQueue(requestId);
        
        // Withdraw from silo to user
        require(address(silo) != address(0), "UnstakeManager: silo not set");
        silo.withdrawTo(user, underlyingAmount);

        // Auto-cleanup logic - trigger cleanup at regular intervals
        processedRequestCounter++;
        if (processedRequestCounter >= lastCleanupCounter + CLEANUP_INTERVAL) {
            _cleanupOldRequests(CLEANUP_BATCH_SIZE);
            lastCleanupCounter = processedRequestCounter;
        }

        emit Claimed(user, underlyingAmount, requestId);
    }
    
    /**
     * @notice Cancel an unstake request
     */
    function cancelUnstake(address user) 
        external 
        override 
        onlyRole(MANAGER_ROLE) 
        nonReentrant 
        returns (bool success) 
    {
        UnstakeRequest storage request = unstakeRequests[user];
        require(request.lsTokenAmount > 0, "UnstakeManager: no pending unstake");
        require(user != address(0), "UnstakeManager: invalid user address");
        require(request.status == RequestStatus.QUEUED || request.status == RequestStatus.PROCESSING, 
                "UnstakeManager: cannot cancel processed request");

        // Store request values before clearing
        uint256 lsTokenAmount = request.lsTokenAmount;
        uint256 underlyingAmount = request.underlyingAmount;
        uint256 requestId = request.requestId;
        
        // Clear request before external calls
        delete unstakeRequests[user];
        delete requestIdToAddress[requestId];
        
        // Remove from queue
        _removeFromQueue(requestId);
        
        // Update queue metrics
        queueLength--;
        totalQueuedUnstakeAmount -= underlyingAmount;
        
        // Return LS tokens to user
        lsToken.mint(user, lsTokenAmount);
        
        emit UnstakeStatusChanged(user, RequestStatus.CANCELLED, requestId);
        
        return true;
    }
    
    /**
     * @notice Clean up outdated requests to optimize gas usage
     */
    function _cleanupOldRequests(uint256 batchSize) internal returns (uint256 cleaned) {
        uint256 count = 0;
        uint256 expirationTime = block.timestamp - 30 days; // Expire requests older than 30 days
        
        // Look for PROCESSED requests in storage and clean up
        for (uint256 i = 0; i < queuedRequestIds.length && count < batchSize; i++) {
            uint256 requestId = queuedRequestIds[i];
            address user = requestIdToAddress[requestId];
            
            if (user == address(0)) continue;
            
            UnstakeRequest storage request = unstakeRequests[user];
            
            // Only clean up processed requests that are old
            if (request.status == RequestStatus.PROCESSED && request.requestTimestamp < expirationTime) {
                delete unstakeRequests[user];
                delete requestIdToAddress[requestId];
                
                // Also remove from the queue if still present
                _removeFromQueue(requestId);
                
                count++;
            }
        }
        
        if (count > 0) {
            emit RequestsCleaned(count);
        }
        
        return count;
    }
    
    /**
     * @notice Get request status and details
     */
    function getRequestInfo(address user) 
        external 
        view 
        override 
        returns (
            RequestStatus status,
            uint256 amount,
            uint256 requestTimestamp,
            uint256 unlockTimestamp
        ) 
    {
        UnstakeRequest storage request = unstakeRequests[user];
        
        if (request.lsTokenAmount == 0) {
            return (RequestStatus.NONE, 0, 0, 0);
        }
        
        return (
            request.status,
            request.underlyingAmount,
            request.requestTimestamp,
            request.requestTimestamp + cooldownPeriod
        );
    }
    
    /**
     * @notice Get view of unstake queue
     */
    function viewUnstakeQueue(uint256 limit) 
        external 
        view 
        override 
        returns (
            address[] memory users,
            uint256[] memory amounts,
            RequestStatus[] memory statuses,
            uint256[] memory requestIds
        ) 
    {
        // Count active requests first (not PROCESSED or CANCELLED)
        uint256 activeCount = 0;
        for (uint256 i = 0; i < queuedRequestIds.length; i++) {
            address user = requestIdToAddress[queuedRequestIds[i]];
            if (user == address(0)) continue;
            
            UnstakeRequest storage request = unstakeRequests[user];
            if (request.status != RequestStatus.PROCESSED && request.status != RequestStatus.CANCELLED) {
                activeCount++;
            }
        }
        
        // Determine actual size
        uint256 size = limit < activeCount ? limit : activeCount;
        
        users = new address[](size);
        amounts = new uint256[](size);
        statuses = new RequestStatus[](size);
        requestIds = new uint256[](size);
        
        // Fill arrays with active queue data only
        uint256 index = 0;
        for (uint256 i = 0; i < queuedRequestIds.length && index < size; i++) {
            uint256 requestId = queuedRequestIds[i];
            address user = requestIdToAddress[requestId];
            
            if (user == address(0)) continue;
            
            UnstakeRequest storage request = unstakeRequests[user];
            
            // Only include active requests (QUEUED or PROCESSING)
            if (request.status != RequestStatus.PROCESSED && request.status != RequestStatus.CANCELLED) {
                users[index] = user;
                amounts[index] = request.underlyingAmount;
                statuses[index] = request.status;
                requestIds[index] = requestId;
                index++;
            }
        }
        
        return (users, amounts, statuses, requestIds);
    }
    
    /**
     * @notice Get queue details
     */
    function getQueueDetails() 
        external 
        view 
        override 
        returns (
            uint256 totalSize,
            uint256 totalUnderlying,
            uint256 queuedCount,
            uint256 processingCount
        ) 
    {
        uint256 _queuedCount = 0;
        uint256 _processingCount = 0;
        
        for (uint256 i = 0; i < queuedRequestIds.length; i++) {
            address user = requestIdToAddress[queuedRequestIds[i]];
            if (user == address(0)) continue;
            
            UnstakeRequest storage request = unstakeRequests[user];
            if (request.status == RequestStatus.QUEUED) {
                _queuedCount++;
            } else if (request.status == RequestStatus.PROCESSING) {
                _processingCount++;
            }
        }
        
        return (
            queueLength,
            totalQueuedUnstakeAmount,
            _queuedCount,
            _processingCount
        );
    }
    
    function grantRole(bytes32 role, address account) public override(AccessControlUpgradeable, IUnstakeManager) onlyRole(getRoleAdmin(role)) {
        super.grantRole(role, account);
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

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        require(newImplementation != address(0), "UnstakeManager: invalid implementation");
        require(upgradeRequested, "UnstakeManager: upgrade not requested");
        require(block.timestamp >= upgradeRequestTime + UPGRADE_TIMELOCK, "UnstakeManager: timelock not expired");
        
        upgradeRequested = false;
        emit UpgradeAuthorized(newImplementation, version);
    }
    
    function updateVersion(string memory _newVersion) external onlyRole(ADMIN_ROLE) {
        version = _newVersion;
        emit VersionUpdated(_newVersion);
    }
    
    uint256[25] private __gap;
}