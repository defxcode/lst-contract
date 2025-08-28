// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @title IVaultFactory
 * @notice Interface for the VaultFactory contract
 */
interface IVaultFactory {

    struct CustodianConfig {
        address wallet;
        uint256 allocationPercent;
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

    // --- Events ---
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
    event GlobalEmergencyControllerUpdated(address indexed newController);


    // --- Functions ---

    // Initialization
    function initialize(
        address vaultImplementation,
        address lsTokenImplementation,
        address siloImplementation,
        address unstakeManagerImplementation,
        address globalEmergencyController,
        address admin
    ) external;

    // Vault creation
    function createVault(
        address underlyingToken,
        string memory underlyingSymbol,
        string memory lsTokenName,
        string memory lsTokenSymbol,
        TokenConfig memory config
    ) external returns (
        address vaultAddress,
        address lsTokenAddress,
        address siloAddress,
        address unstakeManagerAddress
    );

    // Management functions
    function updateTokenConfig(address vault, TokenConfig memory config) external;
    function deactivateVault(address vault) external;
    function reactivateVault(address vault) external;
    function updateGlobalEmergencyController(address newController) external;

    // Custodian Management Functions
    function addCustodianToVault(address vault, address wallet, uint256 allocationPercent) external returns (uint256 custodianId);
    function updateVaultCustodian(address vault, uint256 custodianId, address wallet, uint256 allocationPercent) external;
    function removeVaultCustodian(address vault, uint256 custodianId) external;
    function getVaultCustodians(address vault) external view returns (address[] memory wallets, uint256[] memory allocations);


    // View functions
    function getVaultInfo(address vault) external view returns (VaultInfo memory);
    function getVaultBySymbol(string memory symbol) external view returns (address);
    function getVaultByUnderlying(address underlyingToken) external view returns (address);
    function getAllVaults() external view returns (address[] memory);
    function getTokenConfig(address vault) external view returns (TokenConfig memory);
    function isActiveVault(address vault) external view returns (bool);
}