// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./interfaces/ILSTokenVault.sol";
import "./interfaces/ILSToken.sol";
import "./interfaces/ITokenSilo.sol";
import "./interfaces/IUnstakeManager.sol";
import "./interfaces/IEmergencyController.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title VaultFactory
 * @notice Optimized factory with minimal multi-custodian support and full configuration management
 */
contract VaultFactory is 
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    address public vaultImplementation;
    address public lsTokenImplementation;
    address public siloImplementation;
    address public unstakeManagerImplementation;
    
    IEmergencyController public globalEmergencyController;
    address public globalAdmin;
    
    struct CustodianConfig {
        address wallet;
        uint256 allocationPercent; // 0-100
    }
    
    struct VaultInfo {
        address vault;
        address lsToken;
        address silo;
        address unstakeManager;
        address underlyingToken;
        string underlyingSymbol;
        string lsTokenSymbol;
        uint256 createdAt;
        bool active;
    }

    struct TokenConfig {
        uint256 minDeposit;
        uint256 maxDeposit;
        uint256 maxTotalDeposit;
        uint256 feePercent;
        uint256 cooldownPeriod;
        uint256 floatPercent;
        CustodianConfig[] custodians;
    }
    
    mapping(address => VaultInfo) public vaults;
    mapping(string => address) public symbolToVault;
    mapping(address => address) public underlyingToVault;
    
    // Store vault configurations
    mapping(address => TokenConfig) private vaultConfigs;
    
    address[] public allVaults;
    uint256 public totalVaults;

    uint256 public version;
    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    uint256 public upgradeRequestTime;
    bool public upgradeRequested;
    
    event VaultCreated(
        address indexed vault,
        address indexed underlyingToken,
        address indexed lsToken,
        string underlyingSymbol,
        string lsTokenSymbol,
        address silo,
        address unstakeManager
    );
    event TokenConfigUpdated(address indexed vault, TokenConfig config);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address _vaultImplementation,
        address _lsTokenImplementation,
        address _siloImplementation,
        address _unstakeManagerImplementation,
        address _globalEmergencyController,
        address _admin
    ) external initializer {
        require(_vaultImplementation != address(0), "Invalid vault implementation");
        require(_lsTokenImplementation != address(0), "Invalid lsToken implementation");
        require(_siloImplementation != address(0), "Invalid silo implementation");
        require(_unstakeManagerImplementation != address(0), "Invalid unstake manager implementation");
        require(_globalEmergencyController != address(0), "Invalid emergency controller");
        require(_admin != address(0), "Invalid admin");
        
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        vaultImplementation = _vaultImplementation;
        lsTokenImplementation = _lsTokenImplementation;
        siloImplementation = _siloImplementation;
        unstakeManagerImplementation = _unstakeManagerImplementation;
        globalEmergencyController = IEmergencyController(_globalEmergencyController);
        globalAdmin = _admin;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        
        version = 1;
    }

    function createVault(
        address underlyingToken,
        string memory underlyingSymbol,
        string memory lsTokenName,
        string memory lsTokenSymbol,
        TokenConfig memory config
    ) external onlyRole(ADMIN_ROLE) returns (
        address vaultAddress,
        address lsTokenAddress,
        address siloAddress,
        address unstakeManagerAddress
    ) {
        require(underlyingToken != address(0), "Invalid underlying token");
        require(bytes(underlyingSymbol).length > 0, "Empty underlying symbol");
        require(bytes(lsTokenSymbol).length > 0, "Empty lsToken symbol");
        require(symbolToVault[lsTokenSymbol] == address(0), "Symbol already exists");
        require(underlyingToVault[underlyingToken] == address(0), "Underlying already has vault");
        
        // Validation
        require(config.feePercent <= 30, "Fee too high");
        require(config.cooldownPeriod >= 1 hours && config.cooldownPeriod <= 30 days, "Invalid cooldown");
        require(config.minDeposit > 0, "Min deposit must be > 0");
        require(config.maxDeposit >= config.minDeposit, "Max < min deposit");
        require(config.floatPercent <= 100, "Invalid float percent");
        // Validate custodian configuration
        require(config.custodians.length <= 10, "Too many custodians");
        require(config.custodians.length > 0, "Must have at least one custodian");
        
        // Validate custodian allocations
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < config.custodians.length; i++) {
            require(config.custodians[i].wallet != address(0), "Invalid custodian wallet");
            require(config.custodians[i].allocationPercent > 0, "Invalid allocation");
            totalAllocation += config.custodians[i].allocationPercent;
        }
        require(totalAllocation + config.floatPercent <= 100, "Total allocation > 100%");
        
        // Deploy contracts
        bytes memory lsTokenInitData = abi.encodeWithSelector(
            ILSToken.initialize.selector,
            lsTokenName,
            lsTokenSymbol
        );
        lsTokenAddress = address(new ERC1967Proxy(lsTokenImplementation, lsTokenInitData));
        
        bytes memory siloInitData = abi.encodeWithSelector(
            ITokenSilo.initialize.selector,
            underlyingToken,
            underlyingSymbol,
            address(this)
        );
        siloAddress = address(new ERC1967Proxy(siloImplementation, siloInitData));
        
        bytes memory vaultInitData = abi.encodeWithSelector(
            ILSTokenVault.initialize.selector,
            underlyingToken,
            lsTokenAddress,
            underlyingSymbol,
            lsTokenSymbol,
            globalAdmin
        );
        vaultAddress = address(new ERC1967Proxy(vaultImplementation, vaultInitData));
        
        bytes memory unstakeInitData = abi.encodeWithSelector(
            IUnstakeManager.initialize.selector,
            vaultAddress,
            underlyingToken,
            lsTokenAddress,
            siloAddress
        );
        unstakeManagerAddress = address(new ERC1967Proxy(unstakeManagerImplementation, unstakeInitData));
        
        // Setup roles
        _setupRoles(vaultAddress, lsTokenAddress, siloAddress, unstakeManagerAddress);
        
        // Configure contracts
        ILSTokenVault(vaultAddress).setUnstakeManager(unstakeManagerAddress);
        ILSTokenVault(vaultAddress).setEmergencyController(address(globalEmergencyController));
        ITokenSilo(siloAddress).setEmergencyController(address(globalEmergencyController));
        IUnstakeManager(unstakeManagerAddress).setEmergencyController(address(globalEmergencyController));
        
        // Apply configuration
        _applyConfig(vaultAddress, unstakeManagerAddress, config);
        
        // Setup custodians
        _setupCustodians(vaultAddress, config);
        
        // Store vault info
        VaultInfo memory vaultInfo = VaultInfo({
            vault: vaultAddress,
            lsToken: lsTokenAddress,
            silo: siloAddress,
            unstakeManager: unstakeManagerAddress,
            underlyingToken: underlyingToken,
            underlyingSymbol: underlyingSymbol,
            lsTokenSymbol: lsTokenSymbol,
            createdAt: block.timestamp,
            active: true
        });
        
        vaults[vaultAddress] = vaultInfo;
        symbolToVault[lsTokenSymbol] = vaultAddress;
        underlyingToVault[underlyingToken] = vaultAddress;
        allVaults.push(vaultAddress);
        totalVaults++;
        
        // Store initial configuration
        vaultConfigs[vaultAddress] = config;
        
        emit VaultCreated(vaultAddress, underlyingToken, lsTokenAddress, underlyingSymbol, lsTokenSymbol, siloAddress, unstakeManagerAddress);
        
        return (vaultAddress, lsTokenAddress, siloAddress, unstakeManagerAddress);
    }
    
    function _setupRoles(address vault, address lsToken, address silo, address unstakeManager) internal {
        bytes32 vaultRole = keccak256("VAULT_ROLE");
        bytes32 adminRole = keccak256("ADMIN_ROLE");
        bytes32 minterRole = keccak256("MINTER_ROLE");
    
        ILSToken(lsToken).grantRole(minterRole, vault);
        ILSToken(lsToken).grantRole(minterRole, unstakeManager);
        ILSToken(lsToken).grantRole(adminRole, globalAdmin);

        ITokenSilo(silo).grantRole(vaultRole, unstakeManager);
        ITokenSilo(silo).grantRole(adminRole, globalAdmin);
        
        IUnstakeManager(unstakeManager).grantRole(vaultRole, vault);
        IUnstakeManager(unstakeManager).grantRole(adminRole, globalAdmin);
    }
    
    function _applyConfig(address vault, address unstakeManager, TokenConfig memory config) internal {
        ILSTokenVault(vault).setMaxTotalDeposit(config.maxTotalDeposit);
        ILSTokenVault(vault).setMaxUserDeposit(config.maxDeposit);
        ILSTokenVault(vault).setFeePercent(config.feePercent);
        ILSTokenVault(vault).setFloatPercent(config.floatPercent);
        
        IUnstakeManager(unstakeManager).setCooldownPeriod(config.cooldownPeriod);
        IUnstakeManager(unstakeManager).setMinUnstakeAmount(config.minDeposit);
    }
    
    function _setupCustodians(address vault, TokenConfig memory config) internal {
        ILSTokenVault vaultContract = ILSTokenVault(vault);
        
        // Add custodians dynamically
        for (uint256 i = 0; i < config.custodians.length; i++) {
            if (i == 0) {
                vaultContract.updateCustodian(
                    0,
                    config.custodians[i].wallet,
                    config.custodians[i].allocationPercent
                );
            } else {
                // Add additional custodians
                vaultContract.addCustodian(
                    config.custodians[i].wallet,
                    config.custodians[i].allocationPercent
                );
            }
        }
    }
    
    // Simplified custodian management
    function addCustodianToVault(
        address vault,
        address wallet,
        uint256 allocationPercent
    ) external onlyRole(ADMIN_ROLE) returns (uint256 custodianId) {
        require(vaults[vault].active, "Vault not active");
        require(wallet != address(0), "Invalid wallet");
        require(allocationPercent <= 100, "Invalid allocation");
        
        ILSTokenVault vaultContract = ILSTokenVault(vault);
        return vaultContract.addCustodian(wallet, allocationPercent);
    }
    
    function updateVaultCustodian(
        address vault,
        uint256 custodianId,
        address wallet,
        uint256 allocationPercent
    ) external onlyRole(ADMIN_ROLE) {
        require(vaults[vault].active, "Vault not active");
        require(wallet != address(0), "Invalid wallet");
        require(allocationPercent <= 100, "Invalid allocation");
        
        ILSTokenVault vaultContract = ILSTokenVault(vault);
        vaultContract.updateCustodian(custodianId, wallet, allocationPercent);
    }
    
    function removeVaultCustodian(address vault, uint256 custodianId) external onlyRole(ADMIN_ROLE) {
        require(vaults[vault].active, "Vault not active");
        
        ILSTokenVault vaultContract = ILSTokenVault(vault);
        vaultContract.removeCustodian(custodianId);
    }
    
    function getVaultCustodians(address vault) external view returns (
        address[] memory wallets,
        uint256[] memory allocations
    ) {
        require(vaults[vault].vault != address(0), "Vault does not exist");
        
        ILSTokenVault vaultContract = ILSTokenVault(vault);
        return vaultContract.getAllCustodians();
    }
    
    function deactivateVault(address vault) external onlyRole(ADMIN_ROLE) {
        require(vaults[vault].vault != address(0), "Vault does not exist");
        vaults[vault].active = false;
    }
    
    function reactivateVault(address vault) external onlyRole(ADMIN_ROLE) {
        require(vaults[vault].vault != address(0), "Vault does not exist");
        vaults[vault].active = true;
    }
    
    function updateTokenConfig(address vault, TokenConfig memory config) external onlyRole(ADMIN_ROLE) {
        require(vaults[vault].vault != address(0), "Vault does not exist");
        require(vaults[vault].active, "Vault not active");
        
        // Validate configuration
        require(config.feePercent <= 30, "Fee too high");
        require(config.cooldownPeriod >= 1 hours && config.cooldownPeriod <= 30 days, "Invalid cooldown");
        require(config.minDeposit > 0, "Min deposit must be > 0");
        require(config.maxDeposit >= config.minDeposit, "Max < min deposit");
        require(config.floatPercent <= 100, "Invalid float percent");
        
        // Update vault configuration
        ILSTokenVault vaultContract = ILSTokenVault(vault);
        IUnstakeManager unstakeManagerContract = IUnstakeManager(vaults[vault].unstakeManager);
        
        // Apply limits
        vaultContract.setMaxTotalDeposit(config.maxTotalDeposit);
        vaultContract.setMaxUserDeposit(config.maxDeposit);
        vaultContract.setFeePercent(config.feePercent);
        vaultContract.setFloatPercent(config.floatPercent);
        
        // Apply unstake settings
        unstakeManagerContract.setCooldownPeriod(config.cooldownPeriod);
        unstakeManagerContract.setMinUnstakeAmount(config.minDeposit);
        
        // Store updated config
        vaultConfigs[vault] = config;
        
        emit TokenConfigUpdated(vault, config);
    }
    
    function getTokenConfig(address vault) external view returns (TokenConfig memory) {
        require(vaults[vault].vault != address(0), "Vault does not exist");
        
        // Return stored config if exists, otherwise get current values from vault
        if (vaultConfigs[vault].minDeposit > 0) {
            return vaultConfigs[vault];
        }
        
        // Fallback: read current values from vault contracts
        ILSTokenVault vaultContract = ILSTokenVault(vault);
        IUnstakeManager unstakeManagerContract = IUnstakeManager(vaults[vault].unstakeManager);
        
        TokenConfig memory config;
        config.minDeposit = unstakeManagerContract.minUnstakeAmount();
        config.maxDeposit = vaultContract.maxUserDeposit();
        config.maxTotalDeposit = vaultContract.maxTotalDeposit();
        config.feePercent = vaultContract.feePercent();
        config.cooldownPeriod = unstakeManagerContract.cooldownPeriod();
        config.floatPercent = uint256(vaultContract.floatPercent());

        return config;
    }
    
    function updateGlobalEmergencyController(address newController) external onlyRole(ADMIN_ROLE) {
        require(newController != address(0), "Invalid controller");
        globalEmergencyController = IEmergencyController(newController);
    }
    
    // View functions
    function getVaultInfo(address vault) external view returns (VaultInfo memory) {
        return vaults[vault];
    }
    
    function getVaultBySymbol(string memory symbol) external view returns (address) {
        return symbolToVault[symbol];
    }
    
    function getVaultByUnderlying(address underlyingToken) external view returns (address) {
        return underlyingToVault[underlyingToken];
    }
    
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }
    
    function isActiveVault(address vault) external view returns (bool) {
        return vaults[vault].vault != address(0) && vaults[vault].active;
    }
    
    // Upgrade functions
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
        version++;
    }
    
    uint256[29] private __gap;
}