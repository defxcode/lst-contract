// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { UD60x18, wrap, unwrap } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/ILSToken.sol";
import "./interfaces/IUnderlyingToken.sol";
import "./interfaces/ITokenSilo.sol";
import "./interfaces/IUnstakeManager.sol";
import "./interfaces/IEmergencyController.sol";
import "./LSTokenVaultStorage.sol";

/**
* @title LSTokenVault
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

   IUnstakeManager public unstakeManager;
   IEmergencyController public emergencyController;
   
   string public version;
   uint256 public constant UPGRADE_TIMELOCK = 2 days;
   uint256 public upgradeRequestTime;
   bool public upgradeRequested;

   // Events
   event UnstakeManagerSet(address indexed unstakeManager);
   event EmergencyControllerSet(address indexed emergencyController);
   event Deposited(address indexed user, uint256 underlyingAmount, uint256 lsTokenAmount);
   event TokenTypeUpdated(TokenType tokenType, bool supportsShares);
   event FeesWithdrawn(address indexed receiver, uint256 amount);

   /// @custom:oz-upgrades-unsafe-allow constructor
   constructor() {
       _disableInitializers();
   }

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
       
       _detectTokenType(_underlyingToken);
       
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

   function _detectTokenType(address token) internal {
       try IUnderlyingToken(token).getTotalShares() returns (uint256) {
           tokenType = TokenType.REBASING;
           supportsShares = true;
       } catch {
           tokenType = TokenType.STANDARD;
           supportsShares = false;
       }
   }

   function setTokenType(TokenType _tokenType, bool _supportsShares) external onlyRole(ADMIN_ROLE) {
       tokenType = _tokenType;
       supportsShares = _supportsShares;
       emit TokenTypeUpdated(_tokenType, _supportsShares);
   }

   function setUnstakeManager(address _unstakeManager) external onlyRole(ADMIN_ROLE) {
       require(_unstakeManager != address(0), "Invalid unstake manager");
       unstakeManager = IUnstakeManager(_unstakeManager);
       emit UnstakeManagerSet(_unstakeManager);
   }
   
   function setEmergencyController(address _emergencyController) external onlyRole(ADMIN_ROLE) {
       require(_emergencyController != address(0), "Invalid emergency controller");
       emergencyController = IEmergencyController(_emergencyController);
       emit EmergencyControllerSet(_emergencyController);
   }

   function getCurrentIndex() public view returns (uint256) {
       if (block.timestamp >= vestingEndTime || vestingEndTime == 0) return targetIndex;
       if (vestingEndTime <= lastUpdateTime) return targetIndex;

       uint256 elapsed = block.timestamp - lastUpdateTime;
       uint256 duration = vestingEndTime - lastUpdateTime;
       uint256 delta = targetIndex - lastIndex;
       
       uint256 indexIncrease = calculatePercentage(
           delta,
           elapsed,
           duration
       );

        if (indexIncrease > delta) {
           indexIncrease = delta;
       }
       
       return lastIndex + indexIncrease;
   }

   function addYield(uint256 yieldAmount) external onlyRole(REWARDER_ROLE) {
       require(yieldAmount > 0, "Yield must be > 0");
       require(address(emergencyController) != address(0), "Emergency controller not set");
       require(emergencyController.getEmergencyState() == IEmergencyController.EmergencyState.NORMAL, "Emergency mode");
       require(!emergencyController.isRecoveryModeActive(), "Recovery mode active");
       require(block.timestamp >= vestingEndTime || vestingEndTime == 0, "Previous yield vesting");
       
       uint256 supply = lsToken.totalSupply();
       require(supply > 0, "No LS token supply");

       uint256 feeAmount = calculatePercentage(
           yieldAmount,
           feePercent,
           PERCENT_PRECISION
       );
       uint256 distributableYield = yieldAmount - feeAmount;
       
       if (feeAmount > 0 && feeReceiver != address(0)) {
           totalFeeCollected += feeAmount;
           emit FeesCollected(feeAmount);
       }

       totalCustodianFunds += yieldAmount;
       
       uint256 current = getCurrentIndex();
       uint256 deltaIndex = calculatePercentage(
           distributableYield,
           INDEX_PRECISION,
           supply
       );
       
       uint256 maxIndexIncrease = calculatePercentage(
           current,
           MAX_INDEX_INCREASE_PERCENT,
           PERCENT_PRECISION
       );
       require(deltaIndex <= maxIndexIncrease, "Yield too high");
       
       uint256 newTarget = current + deltaIndex;
       
       uint256 indexChangePercent = calculatePercentage(
           deltaIndex,
           100,
           current
       );
       require(indexChangePercent <= maxPriceImpactPercentage, "Index change too high");

       uint256 oldIndex = lastIndex;
       lastIndex = current;
       targetIndex = newTarget;
       lastUpdateTime = block.timestamp;
       vestingEndTime = block.timestamp + YIELD_VESTING_DURATION;
       lastStateUpdate = block.timestamp;

       emit IndexUpdated(oldIndex, newTarget);
   }

   function deposit(uint256 underlyingAmount) external whenNotPaused nonReentrant {
       _deposit(msg.sender, underlyingAmount, 0);
   }
   
   function deposit(uint256 underlyingAmount, uint256 minLSTokenAmount) external whenNotPaused nonReentrant {
       _deposit(msg.sender, underlyingAmount, minLSTokenAmount);
   }
   
   function depositFor(address user, uint256 underlyingAmount) external whenNotPaused nonReentrant {
       require(hasRole(MANAGER_ROLE, msg.sender), "Not manager");
       _deposit(user, underlyingAmount, 0);
   }
   
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

       uint256 existingValue = convertTokens(
           userBalance,
           currentIndex,
           INDEX_PRECISION,
           false
       );
       require(existingValue + underlyingAmount <= maxUserDeposit, "User limit reached");
       
       _validateRateLimit(underlyingAmount, true);
       
       uint256 totalSupply = lsToken.totalSupply();
       if (totalSupply > 0) {
           uint256 maxAmount = calculatePercentage(
               totalSupply,
               maxTransactionPercentage,
               10000
           );
           require(underlyingAmount <= maxAmount, "Transaction too large");
       }

       uint256 lsTokenAmount = convertTokens(
           underlyingAmount,
           currentIndex,
           INDEX_PRECISION,
           true  // isDeposit = true
       );

       if (minLSTokenAmount > 0) {
           require(lsTokenAmount >= minLSTokenAmount, "Slippage too high");
       }
       require(lsTokenAmount > 0, "LS token amount is 0");

       totalDepositedAmount += underlyingAmount;
       lastStateUpdate = block.timestamp;

       underlyingToken.safeTransferFrom(msg.sender, address(this), underlyingAmount);
       lsToken.mint(user, lsTokenAmount);

       _handleCustodianTransfer(underlyingAmount);
       
       emit Deposited(user, underlyingAmount, lsTokenAmount);
   }
   
    function _handleCustodianTransfer(uint256 underlyingAmount) internal {
       if (custodians.length == 0 || emergencyController.isRecoveryModeActive()) return;

       for (uint256 i = 0; i < custodians.length; i++) {
           if (custodians[i].wallet == address(0)) continue;
           
            uint256 allocation = allocationToPercent(custodians[i].allocation);

            uint256 custodianAmount = calculatePercentage(
                underlyingAmount,
                allocation,
                100
            );
           
           if (custodianAmount > 0) {
               totalCustodianFunds += custodianAmount;
               underlyingToken.safeTransfer(custodians[i].wallet, custodianAmount);
               emit CustodianTransfer(i, custodians[i].wallet, custodianAmount);
           }
       }
   }
   
   function requestUnstake(uint256 lsTokenAmount) external nonReentrant {
       _requestUnstake(lsTokenAmount, 0);
   }
   
   function requestUnstake(uint256 lsTokenAmount, uint256 minUnderlyingAmount) external nonReentrant {
       _requestUnstake(lsTokenAmount, minUnderlyingAmount);
   }
   
   function _requestUnstake(uint256 lsTokenAmount, uint256 minUnderlyingAmount) internal {
       require(address(unstakeManager) != address(0), "Unstake manager not set");
       require(address(emergencyController) != address(0), "Emergency controller not set");
       
       IEmergencyController.EmergencyState state = emergencyController.getEmergencyState();
       require(state != IEmergencyController.EmergencyState.WITHDRAWALS_PAUSED && 
               state != IEmergencyController.EmergencyState.FULL_PAUSE, "Withdrawals paused");
       require(!emergencyController.isRecoveryModeActive(), "Recovery mode active");
       require(unstakeEnabled, "Unstaking disabled");
       
       _validateRateLimit(lsTokenAmount, false);
       
       uint256 totalSupply = lsToken.totalSupply();
       if (totalSupply > 0) {
           uint256 maxAmount = calculatePercentage(
               totalSupply,
               maxTransactionPercentage,
               10000
           );
           require(lsTokenAmount <= maxAmount, "Transaction too large");
       }
       
       unstakeManager.requestUnstake(msg.sender, lsTokenAmount, minUnderlyingAmount, getCurrentIndex());
   }
   
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
   
   function setFloatPercent(uint256 _floatPercent) external onlyRole(ADMIN_ROLE) {
       require(_floatPercent <= 100, "Invalid float percentage");
        uint256 totalCustodianAllocation = 0;
       for (uint256 i = 0; i < custodians.length; i++) {
           totalCustodianAllocation += allocationToPercent(custodians[i].allocation);
       }
       require(_floatPercent + totalCustodianAllocation <= 100, 
           "Float percentage and custodian allocations cannot exceed 100%");
       floatPercent = uint8(_floatPercent);
   }

   function recordCustodianFundsReturn(uint256 amount) external onlyRole(ADMIN_ROLE) {
       require(amount <= totalCustodianFunds, "Amount exceeds custodian funds");
       totalCustodianFunds -= amount;
   }
   
   function setRateLimits(uint256 _maxDailyDeposit, uint256 _maxDailyWithdrawal) external onlyRole(ADMIN_ROLE) {
       depositLimit.maxAmount = uint128(_maxDailyDeposit);
       withdrawalLimit.maxAmount = uint128(_maxDailyWithdrawal);
   }
   
   function setFlashLoanProtection(uint256 _maxTransactionPercentage, uint256 _maxPriceImpactPercentage) external onlyRole(ADMIN_ROLE) {
       require(_maxTransactionPercentage <= 5000, "Percentage too high");
       require(_maxPriceImpactPercentage <= 2000, "Impact too high");
       maxTransactionPercentage = uint16(_maxTransactionPercentage);
       maxPriceImpactPercentage = uint16(_maxPriceImpactPercentage);
   }

   function approveUnstakeManager(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(address(unstakeManager) != address(0), "Unstake manager not set");
        underlyingToken.safeApprove(address(unstakeManager), amount);
    }

   /**
    * @notice Allow a manager to withdraw the accrued protocol fees
    */
   function withdrawFees() external nonReentrant {
       require(hasRole(MANAGER_ROLE, msg.sender), "LSTokenVault: caller is not a manager");
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
       
       return convertTokens(
           underlyingAmount,
           currentIndex,
           INDEX_PRECISION,
           true  // isDeposit = true
       );
   }

   function previewRedeem(uint256 lsTokenAmount) external view returns (uint256 underlyingAmount) {
       uint256 currentIndex = getCurrentIndex();
       
       return convertTokens(
           lsTokenAmount,
           currentIndex,
           INDEX_PRECISION,
           false  // isDeposit = false (withdrawal)
       );
   }
   
   function getStats() external view returns (uint256 currentIndex, uint256 totalDeposited, uint256 totalSupply) {
       return (getCurrentIndex(), totalDepositedAmount, lsToken.totalSupply());
   }

   function getLiquidityStatus() external view returns (
       uint256 vaultBalance,
       uint256 custodianBalance,
       uint256 totalAvailableAssets,
       uint256 indexedLiabilities
   ) {
       vaultBalance = underlyingToken.balanceOf(address(this));
       custodianBalance = totalCustodianFunds;
       totalAvailableAssets = vaultBalance + custodianBalance;
       
       uint256 lsTokenSupply = lsToken.totalSupply();
       uint256 currentIndex = getCurrentIndex();
       
       indexedLiabilities = convertTokens(
           lsTokenSupply,
           currentIndex,
           INDEX_PRECISION,
           false  // isDeposit = false (withdrawal calculation)
       );
   }

   function getTokenInfo() external view returns (
       address underlyingAddr,
       address lsTokenAddr,
       string memory underlyingSym,
       string memory lsTokenSym,
       TokenType tokenTyp,
       bool sharesSupport
   ) {
       return (address(underlyingToken), address(lsToken), underlyingSymbol, lsTokenSymbol, tokenType, supportsShares);
   }

   // --- Admin Functions ---
   
   function setMaxTotalDeposit(uint256 _maxTotal) external onlyRole(ADMIN_ROLE) {
       _setMaxTotalDeposit(_maxTotal);
   }
   
   function setMaxUserDeposit(uint256 _maxUser) external onlyRole(ADMIN_ROLE) {
       _setMaxUserDeposit(_maxUser);
   }
   
   function setMinUnstakeAmount(uint256 _minAmount) external onlyRole(ADMIN_ROLE) {
       _setMinUnstakeAmount(_minAmount);
   }
   
   function setFeePercent(uint256 _feePercent) external onlyRole(ADMIN_ROLE) {
       _setFeePercent(_feePercent);
   }
   
   function setFeeReceiver(address _feeReceiver) external onlyRole(ADMIN_ROLE) {
       _setFeeReceiver(_feeReceiver);
   }
   
   function setStakeEnabled(bool _enabled) external onlyRole(ADMIN_ROLE) {
       _setStakeEnabled(_enabled);
   }
   
   function setUnstakeEnabled(bool _enabled) external onlyRole(ADMIN_ROLE) {
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
   
   uint256[30] private __gap;
}