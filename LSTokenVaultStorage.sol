// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { UD60x18, wrap, unwrap } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./interfaces/ILSToken.sol";

/**
 * @title PrecisionMath
 * @notice An abstract contract that provides safe, high-precision mathematical functions.
 * @dev It is built as a wrapper around the PRBMath UD60x18 library to handle common calculations
 * like percentages and token conversions with 18 decimals of precision, preventing overflow/underflow.
 */
abstract contract PrecisionMath {

    /**
     * @notice Safely converts a standard uint256 into the high-precision UD60x18 format.
     */
    function safeWrap(uint256 value) internal pure returns (UD60x18) {
        require(value <= type(uint256).max / 1e18, "Value too large for UD60x18");
        return wrap(value);
    }

    /**
     * @notice Safely converts a high-precision UD60x18 value back to a standard uint256.
     */
    function safeUnwrap(UD60x18 value) internal pure returns (uint256) {
        uint256 result = unwrap(value);
        require(result >= 0, "UD60x18 unwrap underflow");
        return result;
    }

    /**
     * @notice Calculates `(amount * percentage) / precision` using high-precision math.
     */
    function calculatePercentage(
        uint256 amount,
        uint256 percentage,
        uint256 precision
    ) internal pure returns (uint256) {
        if (amount == 0 || percentage == 0) return 0;

        UD60x18 amountUD = safeWrap(amount);
        UD60x18 percentageUD = safeWrap(percentage);
        UD60x18 precisionUD = safeWrap(precision);

        UD60x18 result = amountUD.mul(percentageUD).div(precisionUD);
        return safeUnwrap(result);
    }

    /**
     * @notice Converts between two token amounts using a given exchange rate.
     * @dev Handles both deposit (underlying to LSToken) and withdrawal (LSToken to underlying) conversions.
     * @param isDeposit If true, calculates `input * precision / rate`. If false, calculates `input * rate / precision`.
     */
    function convertTokens(
        uint256 inputAmount,
        uint256 exchangeRate,
        uint256 precision,
        bool isDeposit
    ) internal pure returns (uint256) {
        if (inputAmount == 0) return 0;

        UD60x18 inputUD = safeWrap(inputAmount);
        UD60x18 rateUD = safeWrap(exchangeRate);
        UD60x18 precisionUD = safeWrap(precision);

        UD60x18 result;

        if (isDeposit) {
            // To get LSToken amount from underlying: (underlying * 1e18) / index
            result = inputUD.mul(precisionUD).div(rateUD);
        } else {
            // To get underlying amount from LSToken: (lsToken * index) / 1e18
            result = inputUD.mul(rateUD).div(precisionUD);
        }

        return safeUnwrap(result);
    }

    /**
     * @notice Converts a percentage (0-100) into a compact uint96 format for efficient storage.
     * @dev Stores the percentage with 16 decimals of precision (percent * 1e16).
     */
    function percentToAllocation(uint256 percent) internal pure returns (uint96) {
        require(percent <= 100, "Percentage cannot exceed 100");
        uint256 allocation = percent * 1e16;
        require(allocation <= type(uint96).max, "Allocation overflow");
        return uint96(allocation);
    }

    /**
     * @notice Converts a stored allocation value back into a standard percentage (0-100).
     */
    function allocationToPercent(uint96 allocation) internal pure returns (uint256) {
        return uint256(allocation) / 1e16;
    }
}

/**
 * @title LSTokenVaultStorage
 * @notice This abstract contract holds all the state variables and internal logic for the LSTokenVault.
 * @dev By separating storage from the main logic contract (LSTokenVault), we can upgrade the logic
 * without needing to migrate the data.
 */
abstract contract LSTokenVaultStorage is Initializable, PrecisionMath {

    // --- Constants ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint256 public constant INDEX_PRECISION = 1e18; // The precision factor for the index (18 decimals).
    uint256 public constant INITIAL_INDEX = 1e18; // The index starts at 1.0.
    uint256 public constant YIELD_VESTING_DURATION = 8 hours; // Duration over which yield is vested.
    uint256 public constant MIN_DEPOSIT_AMOUNT = 0.1 ether; // Minimum deposit size.
    uint256 public constant MAX_INDEX_INCREASE_PERCENT = 10; // Max percentage the index can increase from a single yield deposit.
    uint256 public constant MAX_FEE_PERCENT = 30; // Max protocol fee percentage.
    uint256 public constant PERCENT_PRECISION = 100; // The precision factor for percentages.
    uint256 public constant MAX_CUSTODIANS = 10; // The maximum number of custodian wallets.

    // --- Token References ---
    IERC20Upgradeable public underlyingToken;
    ILSToken public lsToken;

    // --- Token Metadata ---
    string public underlyingSymbol;
    string public lsTokenSymbol;

    // --- Index Tracking ---
    uint256 public lastIndex; // The index value at the start of the current vesting period.
    uint256 public targetIndex; // The target index value to be reached at the end of the vesting period.
    uint256 public lastUpdateTime; // Timestamp of the last time the index was updated.
    uint256 public vestingEndTime; // Timestamp when the current yield vesting period ends.

    // --- Fee Configuration ---
    uint256 public feePercent; // The percentage of yield taken as a protocol fee.
    address public feeReceiver; // The address that receives protocol fees.
    uint256 public totalFeeCollected; // The running total of collected fees waiting for withdrawal.
    uint256 public unclaimedYield;    // Yield forfeited by early unstakers, to be redistributed.

    // --- DYNAMIC Multi-Custodian ---
    struct CustodianData {
        address wallet;
        uint96 allocation; // The percentage of funds allocated to this custodian, stored efficiently.
    }

    CustodianData[] public custodians; // The dynamic array of custodian wallets.
    uint8 public floatPercent; // The percentage of deposits kept in the vault for liquidity.
    uint256 public totalCustodianFunds; // An accounting variable tracking the total funds sent to custodians.

    // --- Core State Variables ---
    bool public stakeEnabled; // A flag to enable/disable deposits.
    bool public unstakeEnabled; // A flag to enable/disable unstaking.
    uint256 public maxTotalDeposit; // The maximum total amount of underlying tokens allowed in the vault.
    uint256 public maxUserDeposit; // The maximum total amount a single user can deposit.
    uint256 public lastStateUpdate; // Timestamp of the last major state change.
    uint256 public totalDepositedAmount; // The total amount of underlying tokens ever deposited.
    mapping(address => uint256) public lastDepositTime; // Timestamp of the last deposit for each user.

    // --- Rate Limiting ---
    struct DailyLimit {
        uint128 maxAmount;
        uint128 currentAmount;
    }
    DailyLimit public depositLimit;
    DailyLimit public withdrawalLimit;
    uint256 public limitWindowStart; // The timestamp when the current 24-hour rate limit window started.

    // --- Flash Loan Protection ---
    uint16 public maxTransactionPercentage; // The max percentage of total supply a single transaction can be.
    uint16 public maxPriceImpactPercentage; // The max percentage the index can change in a single transaction.

    // --- Events ---
    event IndexUpdated(uint256 oldIndex, uint256 newIndex);
    event FeesCollected(uint256 amount);
    event CustodianTransfer(uint256 indexed custodianId, address indexed custodian, uint256 amount);
    event CustodianUpdated(uint256 indexed custodianId, address wallet, uint256 allocation);
    event CustodianAdded(uint256 indexed custodianId, address wallet, uint256 allocation);
    event CustodianRemoved(uint256 indexed custodianId, address wallet);

    /**
     * @notice Sets the initial default values for the vault's configuration upon initialization.
     * @param admin The address to be set as the initial fee receiver.
     */
    function _setupDefaults(address admin) internal {
        feePercent = 10;
        maxTotalDeposit = 1_000_000 ether;
        maxUserDeposit = 10_000 ether;
        floatPercent = 20;
        stakeEnabled = true;
        unstakeEnabled = true;

        feeReceiver = admin;

        depositLimit = DailyLimit({
            maxAmount: 100_000 ether,
            currentAmount: 0
        });

        withdrawalLimit = DailyLimit({
            maxAmount: 50_000 ether,
            currentAmount: 0
        });

        limitWindowStart = block.timestamp;
        maxTransactionPercentage = 500; // 5.00% represented as 500 (precision of 10000)
        maxPriceImpactPercentage = 300; // 3.00% represented as 300
        lastStateUpdate = block.timestamp;
    }

    /**
     * @notice Internal function to add a new custodian.
     */
    function _addCustodian(address wallet, uint256 allocationPercent) internal returns (uint256 custodianId) {
        require(wallet != address(0), "Invalid wallet");
        require(allocationPercent <= 100, "Invalid allocation");
        require(custodians.length < MAX_CUSTODIANS, "Too many custodians");
        for (uint256 i = 0; i < custodians.length; i++) {
            require(custodians[i].wallet != wallet, "Custodian already exists");
        }

        uint256 totalAllocation = allocationPercent;
        for (uint256 i = 0; i < custodians.length; i++) {
            totalAllocation += allocationToPercent(custodians[i].allocation);
        }
        require(uint256(floatPercent) + totalAllocation <= 100, "Total allocation + float cannot exceed 100%");

        custodianId = custodians.length;
        custodians.push(CustodianData({
            wallet: wallet,
            allocation: percentToAllocation(allocationPercent)
        }));

        emit CustodianAdded(custodianId, wallet, allocationPercent);
        return custodianId;
    }

    /**
     * @notice Internal function to update an existing custodian.
     */
    function _updateCustodian(uint256 custodianId, address wallet, uint256 allocationPercent) internal {
        require(custodianId < custodians.length, "Invalid custodian ID");
        require(wallet != address(0), "Invalid wallet");
        require(allocationPercent <= 100, "Invalid allocation");

        uint256 totalAllocation = allocationPercent;
        for (uint256 i = 0; i < custodians.length; i++) {
            if (i != custodianId) {
                totalAllocation += allocationToPercent(custodians[i].allocation);
            }
        }
        require(uint256(floatPercent) + totalAllocation <= 100, "Total allocation + float cannot exceed 100%");

        custodians[custodianId] = CustodianData({
            wallet: wallet,
            allocation: percentToAllocation(allocationPercent)
        });

        emit CustodianUpdated(custodianId, wallet, allocationPercent);
    }

    /**
     * @notice Internal function to remove a custodian efficiently.
     * @dev Uses the "swap with last and pop" method to save gas.
     */
    function _removeCustodian(uint256 custodianId) internal {
        require(custodianId < custodians.length, "Invalid custodian ID");
        require(custodians.length > 1, "Cannot remove last custodian");

        address removedWallet = custodians[custodianId].wallet;

        if (custodianId < custodians.length - 1) {
            custodians[custodianId] = custodians[custodians.length - 1];
        }
        custodians.pop();

        emit CustodianRemoved(custodianId, removedWallet);
    }

    /**
     * @notice A view function to get the current number of custodians.
     */
    function getCustodianCount() public view virtual returns (uint256) {
        return custodians.length;
    }

    /**
     * @notice Internal view function to get a single custodian's allocation.
     */
    function _getCustodianAllocation(uint256 custodianId) internal view returns (uint256) {
        if (custodianId >= custodians.length) return 0;
        return allocationToPercent(custodians[custodianId].allocation);
    }

    /**
     * @notice Internal view function to get all custodians and their allocations.
     */
    function _getAllCustodians() internal view returns (
        address[] memory wallets,
        uint256[] memory allocations
    ) {
        uint256 length = custodians.length;
        wallets = new address[](length);
        allocations = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            wallets[i] = custodians[i].wallet;
            allocations[i] = allocationToPercent(custodians[i].allocation);
        }
    }

    /**
     * @notice Internal function to validate transactions against daily rate limits.
     * @dev Resets the daily limit window if 24 hours have passed.
     */
    function _validateRateLimit(uint256 amount, bool isDeposit) internal {
        if (block.timestamp >= limitWindowStart + 1 days) {
            depositLimit.currentAmount = 0;
            withdrawalLimit.currentAmount = 0;
            limitWindowStart = block.timestamp;
        }

        if (isDeposit) {
            require(depositLimit.currentAmount + amount <= depositLimit.maxAmount, "Daily deposit limit");
            depositLimit.currentAmount += uint128(amount);
        } else {
            require(withdrawalLimit.currentAmount + amount <= withdrawalLimit.maxAmount, "Daily withdrawal limit");
            withdrawalLimit.currentAmount += uint128(amount);
        }
    }

    // --- Internal Setter Functions ---
    // These functions contain the core logic for changing state variables. They are called by the
    // permissioned external functions in the LSTokenVault contract.

    function _setFeePercent(uint256 _feePercent) internal {
        require(_feePercent <= MAX_FEE_PERCENT, "Fee too high");
        feePercent = _feePercent;
    }

    function _setFeeReceiver(address _feeReceiver) internal {
        require(_feeReceiver != address(0), "Invalid fee receiver");
        feeReceiver = _feeReceiver;
    }

    function _setMaxTotalDeposit(uint256 _maxTotalDeposit) internal {
        require(_maxTotalDeposit >= totalDepositedAmount, "Below current total");
        maxTotalDeposit = _maxTotalDeposit;
    }

    function _setMaxUserDeposit(uint256 _maxUserDeposit) internal {
        maxUserDeposit = _maxUserDeposit;
    }

    function _setStakeEnabled(bool _enabled) internal {
        stakeEnabled = _enabled;
    }

    function _setUnstakeEnabled(bool _enabled) internal {
        unstakeEnabled = _enabled;
    }

    uint256[35] private __gap;
}