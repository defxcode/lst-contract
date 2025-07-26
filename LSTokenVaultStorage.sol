// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { UD60x18, wrap, unwrap } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./interfaces/ILSToken.sol";

/**
 * @title PrecisionMath
 * @notice Essential precision-controlled math operations built on top of UD60x18
 */
abstract contract PrecisionMath {

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

    /**
     * @notice Calculate percentage with natural library precision
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
     * @notice Convert tokens with natural library precision
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
            result = inputUD.mul(precisionUD).div(rateUD);
        } else {
            result = inputUD.mul(rateUD).div(precisionUD);
        }
        
        return safeUnwrap(result);
    }

    /**
     * @notice Convert percentage to UD60x18 allocation
     */
function percentToAllocation(uint256 percent) internal pure returns (uint96) {
        require(percent <= 100, "Percentage cannot exceed 100");
        
        uint256 allocation = percent * 1e16; 

        require(allocation <= type(uint96).max, "Allocation overflow");
        return uint96(allocation);
    }
    
    /**
     * @notice Convert allocation back to percentage
     */
    function allocationToPercent(uint96 allocation) internal pure returns (uint256) {
        return uint256(allocation) / 1e16;
    }
}

/**
 * @title LSTokenVaultStorage
 */
abstract contract LSTokenVaultStorage is Initializable, PrecisionMath {
    
    // --- Constants ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint256 public constant INDEX_PRECISION = 1e18;
    uint256 public constant INITIAL_INDEX = 1e18;
    uint256 public constant YIELD_VESTING_DURATION = 8 hours;
    uint256 public constant MIN_DEPOSIT_AMOUNT = 0.1 ether;
    uint256 public constant MAX_INDEX_INCREASE_PERCENT = 10;
    uint256 public constant MAX_FEE_PERCENT = 30;
    uint256 public constant PERCENT_PRECISION = 100;
    uint256 public constant MAX_CUSTODIANS = 10;

    // --- Token references ---
    IERC20Upgradeable public underlyingToken;
    ILSToken public lsToken;
    
    // --- Token metadata ---
    string public underlyingSymbol;
    string public lsTokenSymbol;
    
    // --- Token type ---
    enum TokenType { STANDARD, REBASING, NATIVE_ETH }
    TokenType public tokenType;
    bool public supportsShares;
    
    // --- Index tracking ---
    uint256 public lastIndex;
    uint256 public targetIndex;
    uint256 public lastUpdateTime;
    uint256 public vestingEndTime;
    
    // --- Fee configuration ---
    uint256 public feePercent;
    address public feeReceiver;
    uint256 public totalFeeCollected;
    
    // --- DYNAMIC Multi-Custodian ---
    struct CustodianData {
        address wallet;
        uint96 allocation;
    }
    
    // Dynamic array - only stores actual custodians
    CustodianData[] public custodians;
    uint8 public floatPercent;
    uint256 public totalCustodianFunds;

    // --- Rest of storage variables ---
    bool public stakeEnabled;
    bool public unstakeEnabled;
    uint256 public maxTotalDeposit;
    uint256 public maxUserDeposit;
    uint256 public minUnstakeAmount;
    uint256 public lastStateUpdate;
    uint256 public totalDepositedAmount;
    uint256 public totalWithdrawnAmount;

    // --- Rate limiting ---
    struct DailyLimit {
        uint128 maxAmount;
        uint128 currentAmount;
    }
    
    DailyLimit public depositLimit;
    DailyLimit public withdrawalLimit;
    uint256 public limitWindowStart;
    
    // --- Flash loan protection ---
    uint16 public maxTransactionPercentage;
    uint16 public maxPriceImpactPercentage;

    // --- Events ---
    event IndexUpdated(uint256 oldIndex, uint256 newIndex);
    event FeesCollected(uint256 amount);
    event CustodianTransfer(uint256 indexed custodianId, address indexed custodian, uint256 amount);
    event CustodianUpdated(uint256 indexed custodianId, address wallet, uint256 allocation);
    event CustodianAdded(uint256 indexed custodianId, address wallet, uint256 allocation);
    event CustodianRemoved(uint256 indexed custodianId, address wallet);

    function _setupDefaults(address admin) internal {
        feePercent = 10;
        maxTotalDeposit = 1_000_000 ether;
        maxUserDeposit = 10_000 ether;
        minUnstakeAmount = 0.1 ether;
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
        maxTransactionPercentage = 500; // 5%
        maxPriceImpactPercentage = 300; // 3%
        lastStateUpdate = block.timestamp;
    }
    
    /**
     * @notice Add new custodian
     */
    function _addCustodian(address wallet, uint256 allocationPercent) internal returns (uint256 custodianId) {
        require(wallet != address(0), "Invalid wallet");
        require(allocationPercent <= 100, "Invalid allocation");
        require(custodians.length < MAX_CUSTODIANS, "Too many custodians");

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
     * @notice Update existing custodian
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
     * @notice Remove custodian (swap with last and pop)
     */
    function _removeCustodian(uint256 custodianId) internal {
        require(custodianId < custodians.length, "Invalid custodian ID");
        require(custodians.length > 1, "Cannot remove last custodian");
        
        address removedWallet = custodians[custodianId].wallet;
        
        // Swap with last element and pop
        if (custodianId < custodians.length - 1) {
            custodians[custodianId] = custodians[custodians.length - 1];
        }
        custodians.pop();
        
        emit CustodianRemoved(custodianId, removedWallet);
    }
    
    /**
     * @notice Get custodian count
     */
    function getCustodianCount() public view virtual returns (uint256) {
        return custodians.length;
    }
    
    /**
     * @notice Get custodian allocation percentage
     */
    function _getCustodianAllocation(uint256 custodianId) internal view returns (uint256) {
        if (custodianId >= custodians.length) return 0;
        return allocationToPercent(custodians[custodianId].allocation);
    }
    
    /**
     * @notice Get all custodians (dynamic return)
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

    // Keep essential validation functions
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
    
    // Minimal setter functions
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
    
    function _setMinUnstakeAmount(uint256 _minUnstakeAmount) internal {
        require(_minUnstakeAmount > 0, "Must be > 0");
        minUnstakeAmount = _minUnstakeAmount;
    }
    
    function _setStakeEnabled(bool _enabled) internal {
        stakeEnabled = _enabled;
    }
    
    function _setUnstakeEnabled(bool _enabled) internal {
        unstakeEnabled = _enabled;
    }
    
    uint256[30] private __gap;
}