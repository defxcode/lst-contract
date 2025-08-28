// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// External libraries and contracts
import { UD60x18, wrap, unwrap } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

// Internal interfaces
import "./interfaces/ILSToken.sol";
import "./interfaces/ITokenSilo.sol";
import "./interfaces/IUnstakeManager.sol";
import "./interfaces/IEmergencyController.sol";
import "./interfaces/ILSTokenVault.sol";

/**
* @title UnstakeManager
* @notice This contract manages the entire asynchronous unstaking process. It handles user requests,
* manages a queue of pending unstakes, facilitates processing by an admin/manager, and allows users
* to claim their funds from the TokenSilo after a cooldown period.
*/
contract UnstakeManager is
Initializable,
AccessControlUpgradeable,
ReentrancyGuardUpgradeable,
UUPSUpgradeable,
IUnstakeManager
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // --- Roles ---
    /// @notice The VAULT_ROLE is granted to the LSTokenVault, allowing it to initiate unstake requests on behalf of users.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice The MANAGER_ROLE is for off-chain operators who process the unstake queue.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // --- State Variables ---

    // Core contract references
    address public vault;
    IERC20Upgradeable public underlyingToken;
    ILSToken public lsToken;
    ITokenSilo public silo;
    IEmergencyController public emergencyController;

    // Token metadata
    string public underlyingSymbol;
    string public lsTokenSymbol;

    /// @notice A struct representing a single user's unstake request.
    struct UnstakeRequest {
        uint256 lsTokenAmount;      // The original amount of LSTokens burned.
        uint256 requestTimestamp;   // The timestamp of the request.
        uint256 underlyingAmount;   // The calculated amount of underlying tokens owed.
        RequestStatus status;       // The current status of the request (Queued, Processing, etc.).
        uint256 requestId;          // A unique ID for the request.
    }

    // --- Configuration ---
    uint256 public cooldownPeriod;      // The mandatory waiting period before claiming.
    uint256 public maxCooldownPeriod;   // An upper bound for the cooldown period, for safety.
    uint256 public minUnstakeAmount;    // The minimum amount of LSTokens a user can unstake.

    // --- Queue Management ---
    uint256 private nextRequestId; // A counter to generate unique request IDs.
    /// @notice Maps a user's address to their single active unstake request.
    mapping(address => UnstakeRequest) public unstakeRequests;
    /// @notice Maps a unique request ID back to the user's address for quick lookups.
    mapping(uint256 => address) public requestIdToAddress;

    /// @notice An array of all request IDs currently in the queue (status QUEUED or PROCESSING).
    uint256[] public queuedRequestIds;
    uint256 public queueLength; // The total number of requests in the queue.
    uint256 public totalQueuedUnstakeAmount; // The total value of underlying tokens in the queue.

    // Auto-cleanup tracking
    uint256 private processedRequestCounter;
    uint256 private lastCleanupCounter;
    uint256 private constant CLEANUP_INTERVAL = 50;
    uint256 private constant CLEANUP_BATCH_SIZE = 5;

    // --- Upgrade Control ---
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
     * @notice Initializes the UnstakeManager contract.
     * @dev Called by the VaultFactory during deployment.
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

        underlyingSymbol = _getTokenSymbol(_underlyingToken);
        lsTokenSymbol = _getTokenSymbol(_lsToken);

        nextRequestId = 1;
        processedRequestCounter = 0;
        lastCleanupCounter = 0;

        cooldownPeriod = 7 days;
        maxCooldownPeriod = 30 days;
        minUnstakeAmount = 0.1 ether;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(VAULT_ROLE, _vault);
        _grantRole(MANAGER_ROLE, msg.sender);

        require(hasRole(VAULT_ROLE, _vault), "UnstakeManager: vault role not granted");
        version = "1.0.0";
    }

    /**
     * @notice Safely gets a token's symbol, returning "UNKNOWN" if the call fails.
     */
    function _getTokenSymbol(address token) internal view returns (string memory) {
        try IERC20MetadataUpgradeable(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "UNKNOWN";
        }
    }

    /**
     * @notice Internal function to transfer underlying tokens from the main LSTokenVault.
     * @dev This is a critical step in the processing flow, moving funds from the vault to this contract.
     */
    function _transferFromVault(uint256 amount) internal {
        require(underlyingToken.balanceOf(vault) >= amount, "UnstakeManager: insufficient vault balance");
        underlyingToken.safeTransferFrom(vault, address(this), amount);
    }

    /**
     * @notice Sets the address of the global EmergencyController.
     */
    function setEmergencyController(address _emergencyController) external onlyRole(ADMIN_ROLE) {
        require(_emergencyController != address(0), "UnstakeManager: invalid controller");
        emergencyController = IEmergencyController(_emergencyController);
        emit EmergencyControllerSet(_emergencyController);
    }

    /**
     * @notice Sets the cooldown period for unstaking.
     */
    function setCooldownPeriod(uint256 _period) external onlyRole(ADMIN_ROLE) {
        require(_period > 0 && _period <= maxCooldownPeriod, "UnstakeManager: invalid period");
        cooldownPeriod = _period;
        emit CooldownPeriodSet(_period);
    }

    /**
     * @notice Sets the minimum amount for a single unstake request.
     */
    function setMinUnstakeAmount(uint256 _amount) external onlyRole(ADMIN_ROLE) {
        require(_amount > 0, "UnstakeManager: amount must be > 0");
        minUnstakeAmount = _amount;
        emit MinUnstakeAmountSet(_amount);
    }

    /**
     * @notice Creates an unstake request for a user.
     * @dev This function is the entry point for the unstaking flow. It can only be called by the LSTokenVault.
     * It burns the user's LSTokens, calculates the equivalent underlying amount, and adds a request to the queue.
     * @param user The user initiating the unstake.
     * @param lsTokenAmount The amount of LSTokens to burn.
     * @param minUnderlyingAmount The minimum underlying amount the user will accept (slippage protection).
     * @param currentIndex The current LSToken index, provided by the vault.
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

        lsToken.burnFrom(user, lsTokenAmount);

        UD60x18 lsTokenUD = safeWrap(lsTokenAmount);
        UD60x18 currentIndexUD = safeWrap(currentIndex);
        UD60x18 precisionUD = safeWrap(1e18);

        uint256 underlyingAmount = safeUnwrap(lsTokenUD.mul(currentIndexUD).div(precisionUD));

        if (minUnderlyingAmount > 0) {
            require(underlyingAmount >= minUnderlyingAmount, "UnstakeManager: slippage too high");
        }
        require(underlyingAmount > 0, "UnstakeManager: underlying amount is 0");

        uint256 requestId = nextRequestId++;
        unstakeRequests[user] = UnstakeRequest({
            lsTokenAmount: lsTokenAmount,
            requestTimestamp: block.timestamp,
            underlyingAmount: underlyingAmount,
            status: RequestStatus.QUEUED,
            requestId: requestId
        });

        requestIdToAddress[requestId] = user;
        queuedRequestIds.push(requestId);
        queueLength++;
        totalQueuedUnstakeAmount += underlyingAmount;

        emit UnstakeRequested(user, lsTokenAmount, block.timestamp + cooldownPeriod, requestId);
        emit UnstakeStatusChanged(user, RequestStatus.QUEUED, requestId);
    }

    /**
     * @notice Allows a manager to flag specific requests as ready for processing.
     * @dev This is the first step of the two-step manual processing flow. It changes the request
     * status from `QUEUED` to `PROCESSING`.
     * @param requestIds An array of request IDs to mark.
     * @return processedCount The number of requests successfully marked.
     */
    function markRequestsForProcessing(uint256[] calldata requestIds)
    external override onlyRole(MANAGER_ROLE) nonReentrant returns (uint256 processedCount)
    {
        require(requestIds.length > 0, "UnstakeManager: empty request list");
        uint256 count = 0;

        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];
            address user = requestIdToAddress[requestId];

            if (user == address(0)) continue;
            UnstakeRequest storage request = unstakeRequests[user];

            if (request.status != RequestStatus.QUEUED || request.requestId != requestId) continue;
            request.status = RequestStatus.PROCESSING;

            count++;
            emit UnstakeStatusChanged(user, RequestStatus.PROCESSING, requestId);
        }

        return count;
    }

    /**
     * @notice internal function to remove a request ID from the queue array.
     * @dev Uses the "swap with last and pop" method to avoid costly array shifting.
     */
    function _removeFromQueue(uint256 requestId) private {
        for (uint256 i = 0; i < queuedRequestIds.length; i++) {
            if (queuedRequestIds[i] == requestId) {
                if (i < queuedRequestIds.length - 1) {
                    queuedRequestIds[i] = queuedRequestIds[queuedRequestIds.length - 1];
                }
                queuedRequestIds.pop();
                break;
            }
        }
    }

    /**
     * @notice Processes a batch of unstake requests that have been marked for processing.
     * @dev This is the second step of the manual processing flow. It pulls the required amount of
     * underlying tokens from the LSTokenVault and deposits them into the TokenSilo for the users.
     * @param batchSize The maximum number of requests to process in this transaction.
     * @return processed The number of requests successfully processed.
     * @return remaining The number of requests still left in the queue.
     */
    function processUnstakeQueue(uint256 batchSize)
    external override onlyRole(MANAGER_ROLE) nonReentrant returns (uint256 processed, uint256 remaining)
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
        address[] memory usersToProcess = new address[](batchSize);
        uint256[] memory requestIdsToProcess = new uint256[](batchSize);
        uint256[] memory amountsToProcess = new uint256[](batchSize);

        uint256 batchIndex = 0;
        for (uint256 i = 0; i < queuedRequestIds.length && batchIndex < batchSize; i++) {
            uint256 requestId = queuedRequestIds[i];
            address user = requestIdToAddress[requestId];

            if (user == address(0)) continue;

            UnstakeRequest storage request = unstakeRequests[user];
            if (request.status != RequestStatus.PROCESSING || request.requestId != requestId) continue;

            if (totalAmountToProcess + request.underlyingAmount <= vaultBalance) {
                usersToProcess[batchIndex] = user;
                requestIdsToProcess[batchIndex] = requestId;
                amountsToProcess[batchIndex] = request.underlyingAmount;
                totalAmountToProcess += request.underlyingAmount;
                batchIndex++;
            }
        }

        if (batchIndex > 0 && totalAmountToProcess > 0) {
            _transferFromVault(totalAmountToProcess);
            underlyingToken.safeApprove(address(silo), 0);
            underlyingToken.safeApprove(address(silo), totalAmountToProcess);

            for (uint256 i = 0; i < batchIndex; i++) {
                address user = usersToProcess[i];
                uint256 requestId = requestIdsToProcess[i];
                uint256 amount = amountsToProcess[i];

                if (user == address(0) || amount == 0) continue;
                try silo.depositFor(user, amount) {
                    unstakeRequests[user].status = RequestStatus.PROCESSED;
                    _removeFromQueue(requestId);
                    queueLength--;
                    totalQueuedUnstakeAmount -= amount;
                    successCount++;
                    emit UnstakeProcessed(user, amount, requestId);
                    emit UnstakeStatusChanged(user, RequestStatus.PROCESSED, requestId);
                } catch {
                    emit UnstakeProcessingFailed(user, amount, requestId);
                }
            }
        }

        return (successCount, queueLength);
    }

    /**
     * @notice Allows a manager to process a single user's unstake request directly, bypassing the two-step flow.
     * @dev This is useful for handling specific or urgent requests. It moves a request from `QUEUED`
     * directly to `PROCESSED`.
     * @param user The address of the user whose request should be processed.
     * @return processed True if the request was successfully processed.
     */
    function processUserUnstake(address user)
    external override onlyRole(MANAGER_ROLE) nonReentrant returns (bool processed)
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

        request.status = RequestStatus.PROCESSED;
        emit UnstakeStatusChanged(user, RequestStatus.PROCESSED, requestId);
        _transferFromVault(underlyingAmount);
        underlyingToken.safeApprove(address(silo), 0);
        underlyingToken.safeApprove(address(silo), underlyingAmount);

        silo.depositFor(user, underlyingAmount);

        _removeFromQueue(requestId);
        queueLength--;
        totalQueuedUnstakeAmount -= underlyingAmount;
        emit UnstakeProcessed(user, underlyingAmount, requestId);

        return true;
    }

    /**
     * @notice Allows a user to claim their underlying tokens after the cooldown period has ended.
     * @dev This function is callable by the user themselves. It commands the TokenSilo to transfer
     * the funds to the user and cleans up the completed request from storage.
     * @param user The user who is claiming their funds.
     */
    function claim(address user) external override nonReentrant {
        require(msg.sender == vault || msg.sender == user, "UnstakeManager: not authorized");
        require(address(emergencyController) != address(0), "UnstakeManager: emergency controller not set");

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

        delete unstakeRequests[user];
        delete requestIdToAddress[requestId];
        _removeFromQueue(requestId);

        require(address(silo) != address(0), "UnstakeManager: silo not set");
        silo.withdrawTo(user, underlyingAmount);

        processedRequestCounter++;
        if (processedRequestCounter >= lastCleanupCounter + CLEANUP_INTERVAL) {
            _cleanupOldRequests(CLEANUP_BATCH_SIZE);
            lastCleanupCounter = processedRequestCounter;
        }

        emit Claimed(user, underlyingAmount, requestId);
    }

    /**
     * @notice Allows a manager to cancel a user's pending unstake request.
     * @dev This function deletes the request and re-mints the user's LSTokens, effectively
     * reversing the `requestUnstake` action.
     * @param user The user whose request should be cancelled.
     * @return success True if the cancellation was successful.
     */
    function cancelUnstake(address user)
    external override onlyRole(MANAGER_ROLE) nonReentrant returns (bool success)
    {
        UnstakeRequest storage request = unstakeRequests[user];
        require(request.lsTokenAmount > 0, "UnstakeManager: no pending unstake");
        require(user != address(0), "UnstakeManager: invalid user address");
        require(request.status == RequestStatus.QUEUED || request.status == RequestStatus.PROCESSING,
            "UnstakeManager: cannot cancel processed request");
        uint256 lsTokenAmount = request.lsTokenAmount;
        uint256 underlyingAmount = request.underlyingAmount;
        uint256 requestId = request.requestId;

        delete unstakeRequests[user];
        delete requestIdToAddress[requestId];

        _removeFromQueue(requestId);
        queueLength--;
        totalQueuedUnstakeAmount -= underlyingAmount;
        lsToken.mint(user, lsTokenAmount);

        emit UnstakeStatusChanged(user, RequestStatus.CANCELLED, requestId);
        return true;
    }

    /**
     * @notice An internal function to clean up very old, completed request data.
     * @dev Flagged as potentially redundant, as the primary functions already clean up after themselves.
     */
    function _cleanupOldRequests(uint256 batchSize) internal returns (uint256 cleaned) {
        uint256 count = 0;
        uint256 expirationTime = block.timestamp - 30 days;

        for (uint256 i = 0; i < queuedRequestIds.length && count < batchSize; i++) {
            uint256 requestId = queuedRequestIds[i];
            address user = requestIdToAddress[requestId];

            if (user == address(0)) continue;

            UnstakeRequest storage request = unstakeRequests[user];
            if (request.status == RequestStatus.PROCESSED && request.requestTimestamp < expirationTime) {
                delete unstakeRequests[user];
                delete requestIdToAddress[requestId];
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
     * @notice A view function to get the status and details of a specific user's unstake request.
     */
    function getRequestInfo(address user)
    external view override returns (
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
     * @notice A view function to get a paginated list of all active requests in the queue.
     */
    function viewUnstakeQueue(uint256 limit)
    external view override returns (
        address[] memory users,
        uint256[] memory amounts,
        RequestStatus[] memory statuses,
        uint256[] memory requestIds
    )
    {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < queuedRequestIds.length; i++) {
            address user = requestIdToAddress[queuedRequestIds[i]];
            if (user == address(0)) continue;

            UnstakeRequest storage request = unstakeRequests[user];
            if (request.status != RequestStatus.PROCESSED && request.status != RequestStatus.CANCELLED) {
                activeCount++;
            }
        }

        uint256 size = limit < activeCount ? limit : activeCount;

        users = new address[](size);
        amounts = new uint256[](size);
        statuses = new RequestStatus[](size);
        requestIds = new uint256[](size);
        uint256 index = 0;
        for (uint256 i = 0; i < queuedRequestIds.length && index < size; i++) {
            uint256 requestId = queuedRequestIds[i];
            address user = requestIdToAddress[requestId];

            if (user == address(0)) continue;

            UnstakeRequest storage request = unstakeRequests[user];
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
     * @notice A view function to get high-level metrics about the state of the unstake queue.
     */
    function getQueueDetails()
    external view override returns (
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

    // --- Role and Upgrade Functions ---

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