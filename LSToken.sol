// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title LSToken - Liquid Staking Token
 * @notice This token is minted when users deposit underlying tokens into the vault and burned on redemption
 */
contract LSToken is 
    Initializable, 
    ERC20PermitUpgradeable, 
    AccessControlUpgradeable,
    UUPSUpgradeable 
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    // Contract version for tracking upgrades
    string public version;
    
    // Upgrade timelock
    struct UpgradeControl {
        uint256 requestTime;
        bool requested;
    }
    
    UpgradeControl public upgradeControl;
    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    
    // Events
    event VersionUpdated(string newVersion);
    event UpgradeRequested(uint256 requestTime);
    event UpgradeAuthorized(address indexed implementation, string currentVersion);
    event UpgradeCancelled(uint256 requestTime);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer function
     * @param name Token name
     * @param symbol Token symbol
     */
    function initialize(string memory name, string memory symbol) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        
        version = "1.0.0";
    }

    /**
     * @notice Returns the number of decimals
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /**
     * @notice Mint LS tokens to an address
     * @param to Address to receive LS tokens
     * @param amount Amount of LS tokens to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "LSToken: cannot mint to zero address");
        _mint(to, amount);
    }

    /**
     * @notice Burn LS tokens from an address
     * @param from Address from which LS tokens will be burned
     * @param amount Amount of LS tokens to burn
     */
    function burnFrom(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(from != address(0), "LSToken: cannot burn from zero address");
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
    }
    
    /**
     * @notice Update the contract version
     * @param _newVersion New version string
     */
    function updateVersion(string memory _newVersion) external onlyRole(ADMIN_ROLE) {
        version = _newVersion;
        emit VersionUpdated(_newVersion);
    }
    
    /**
     * @notice Request a contract upgrade with timelock
     */
    function requestUpgrade() external onlyRole(ADMIN_ROLE) {
        if (upgradeControl.requested) {
            require(block.timestamp >= upgradeControl.requestTime + UPGRADE_TIMELOCK, 
                "Previous upgrade request still in timelock period");
        }
        upgradeControl.requestTime = block.timestamp;
        upgradeControl.requested = true;
        emit UpgradeRequested(upgradeControl.requestTime);
    }

    /**
     * @notice Cancel an upgrade request
     */
    function cancelUpgrade() external onlyRole(ADMIN_ROLE) {
        require(upgradeControl.requested, "No upgrade to cancel");
        upgradeControl.requested = false;
        emit UpgradeCancelled(upgradeControl.requestTime);
        upgradeControl.requestTime = 0;
    }
    
    /**
     * @notice Check if an upgrade is requested
     * @return requested Whether an upgrade is requested
     * @return requestTime When the upgrade was requested
     */
    function upgradeRequested() external view returns (bool requested, uint256 requestTime) {
        return (upgradeControl.requested, upgradeControl.requestTime);
    }
    
    /**
     * @notice Authorize an upgrade
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        require(newImplementation != address(0), "LSToken: invalid implementation");
        
        require(upgradeControl.requested, "LSToken: upgrade not requested");
        require(block.timestamp >= upgradeControl.requestTime + UPGRADE_TIMELOCK, "LSToken: timelock not expired");
        
        // Reset upgrade request flag once used
        upgradeControl.requested = false;
        
        emit UpgradeAuthorized(newImplementation, version);
    }
    
    uint256[30] private __gap;
}