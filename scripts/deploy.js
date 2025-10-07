// scripts/deploy.js
const { ethers, upgrades, network } = require("hardhat");
const fs = require('fs');
const path = require('path');

const TOKEN_CONFIGS = {
    rETH: {
        name: "rETH",
        addresses: {
            sepolia: '0x7BD3f7407F1Abdd5da9d3AbBf2601904bcB72481',
            mainnet: '0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84'
        },
        lsTokenName: "Defx Staked rETH",
        lsTokenSymbol: "drETH",
        config: {
            minDeposit: "0.1",
            maxDeposit: "10000",
            maxTotalDeposit: "1000000",
            feePercent: 10,
            cooldownPeriod: 7 * 86400, // 7 days
            floatPercent: 20,
        }
    }
};

async function main() {
    const [deployer] = await ethers.getSigners();

    const tokenName = process.argv[2] || 'rETH';
    const tokenConfig = TOKEN_CONFIGS[tokenName];
    if (!tokenConfig) throw new Error(`Unknown token: ${tokenName}`);

    console.log(`Deploying ${tokenName} with deployer: ${deployer.address}`);
    console.log(`Deployer balance: ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} ETH`);

    const isLocal = ['hardhat', 'localhost'].includes(network.name);

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
    const VAULT_ROLE = ethers.keccak256(ethers.toUtf8Bytes("VAULT_ROLE"));
    const MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MANAGER_ROLE"));
    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));

    let underlyingTokenAddress;
    let underlyingTokenDecimals;

    if (isLocal) {
        console.log("Deploying mock token for local testing...");
        const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
        const mockToken = await MockERC20.deploy(tokenName, tokenName, 18);
        await mockToken.waitForDeployment();
        underlyingTokenAddress = await mockToken.getAddress();
        underlyingTokenDecimals = 18; // Mock token has 18 decimals
        console.log(`Mock ${tokenName} deployed at: ${underlyingTokenAddress}`);
    } else {
        underlyingTokenAddress = tokenConfig.addresses[network.name];
        if (!underlyingTokenAddress) {
            throw new Error(`No ${tokenName} address configured for network ${network.name}`);
        }
        const underlyingTokenContract = await ethers.getContractAt("IERC20MetadataUpgradeable", underlyingTokenAddress);
        underlyingTokenDecimals = await underlyingTokenContract.decimals();
    }
    console.log(`Using Underlying Token at: ${underlyingTokenAddress} with ${underlyingTokenDecimals} decimals`);

    // Deploy EmergencyController
    console.log("Deploying EmergencyController...");
    const EmergencyController = await ethers.getContractFactory("EmergencyController", deployer);
    const emergencyController = await upgrades.deployProxy(EmergencyController, [deployer.address], { kind: 'uups' });
    await emergencyController.waitForDeployment();
    const emergencyControllerAddress = await emergencyController.getAddress();
    console.log(`EmergencyController deployed at: ${emergencyControllerAddress}`);

    // Deploy implementation contracts
    console.log("Deploying implementation contracts...");

    const LSToken = await ethers.getContractFactory("LSToken", deployer);
    const lsTokenImpl = await LSToken.deploy();
    await lsTokenImpl.waitForDeployment();
    console.log(`LSToken implementation: ${await lsTokenImpl.getAddress()}`);

    const LSTokenVault = await ethers.getContractFactory("LSTokenVault", deployer);
    const vaultImpl = await LSTokenVault.deploy();
    await vaultImpl.waitForDeployment();
    console.log(`LSTokenVault implementation: ${await vaultImpl.getAddress()}`);

    const TokenSilo = await ethers.getContractFactory("TokenSilo", deployer);
    const siloImpl = await TokenSilo.deploy();
    await siloImpl.waitForDeployment();
    console.log(`TokenSilo implementation: ${await siloImpl.getAddress()}`);

    const UnstakeManager = await ethers.getContractFactory("UnstakeManager", deployer);
    const unstakeImpl = await UnstakeManager.deploy();
    await unstakeImpl.waitForDeployment();
    console.log(`UnstakeManager implementation: ${await unstakeImpl.getAddress()}`);

    // PROXY DEPLOYMENT
    console.log("\n=== DEPLOYING PROXIES ===");

    console.log("Deploying LSToken proxy...");
    const lsToken = await upgrades.deployProxy(LSToken, [tokenConfig.lsTokenName, tokenConfig.lsTokenSymbol], { kind: 'uups' });
    await lsToken.waitForDeployment();
    const lsTokenAddress = await lsToken.getAddress();

    // Deploy Vault first as its address is needed by other contracts
    const vault = await upgrades.deployProxy(LSTokenVault, [underlyingTokenAddress, lsTokenAddress, tokenConfig.name, tokenConfig.lsTokenSymbol, deployer.address], { kind: 'uups' });
    await vault.waitForDeployment();
    const vaultAddress = await vault.getAddress();
    console.log(`LSTokenVault proxy deployed at: ${vaultAddress}`);

    // Deploy Silo, providing the deployer as the initial fee collector
    const silo = await upgrades.deployProxy(TokenSilo, [underlyingTokenAddress, tokenConfig.name, vaultAddress, deployer.address], { kind: 'uups', initializer: 'initialize(address,string,address,address)' });
    await silo.waitForDeployment();
    const siloAddress = await silo.getAddress();
    console.log(`TokenSilo proxy deployed at: ${siloAddress}`);

    // Deploy UnstakeManager
    const unstakeManager = await upgrades.deployProxy(UnstakeManager, [vaultAddress, underlyingTokenAddress, lsTokenAddress, siloAddress], { kind: 'uups' });
    await unstakeManager.waitForDeployment();
    const unstakeManagerAddress = await unstakeManager.getAddress();
    console.log(`UnstakeManager proxy deployed at: ${unstakeManagerAddress}`);

    // --- DEPLOY VAULT MANAGER FOR THIS VAULT ---
    console.log("\n=== DEPLOYING VAULT MANAGER ===");
    const VaultManager = await ethers.getContractFactory("VaultManager", deployer);
    const vaultManager = await upgrades.deployProxy(
        VaultManager,
        [vaultAddress, deployer.address], // Initialize with vault and admin address
        { kind: 'uups', initializer: 'initialize' }
    );
    await vaultManager.waitForDeployment();
    const vaultManagerAddress = await vaultManager.getAddress();
    console.log(`VaultManager for ${tokenName} deployed at: ${vaultManagerAddress}`);

    // --- COMPLETE ROLE AND CONTRACT SETUP ---
    console.log("\n=== SETTING UP ROLES AND CONNECTIONS ===");

    // 1. Grant critical inter-contract roles
    await lsToken.grantRole(MINTER_ROLE, vaultAddress);
    await lsToken.grantRole(MINTER_ROLE, unstakeManagerAddress);
    console.log("LSToken minting roles configured");

    await silo.grantRole(VAULT_ROLE, unstakeManagerAddress);
    console.log("TokenSilo VAULT_ROLE configured for UnstakeManager");

    await unstakeManager.grantRole(VAULT_ROLE, vaultAddress);
    console.log("UnstakeManager VAULT_ROLE configured for LSTokenVault");

    // 2. Grant necessary roles to the VaultManager
    await vault.grantRole(MANAGER_ROLE, vaultManagerAddress);
    console.log(`LSTokenVault MANAGER_ROLE granted to VaultManager`);

    await unstakeManager.grantRole(ADMIN_ROLE, vaultManagerAddress);
    console.log(`UnstakeManager ADMIN_ROLE granted to VaultManager`);

    await silo.grantRole(ADMIN_ROLE, vaultManagerAddress);
    console.log(`TokenSilo ADMIN_ROLE granted to VaultManager`);

    // 3. Connect contracts to each other and to the emergency controller
    await vault.setUnstakeManager(unstakeManagerAddress);
    await vault.setEmergencyController(emergencyControllerAddress);
    await silo.setEmergencyController(emergencyControllerAddress);
    await unstakeManager.setEmergencyController(emergencyControllerAddress);
    console.log("All contracts connected to EmergencyController");

    await vault.approveUnstakeManager(ethers.MaxUint256);
    console.log("Approved UnstakeManager to spend underlying tokens from the vault");

    // 4. Connect VaultManager to its managed contracts
    await vaultManager.setUnstakeManager(unstakeManagerAddress);
    await vaultManager.setTokenSilo(siloAddress);
    await vaultManager.setEmergencyController(emergencyControllerAddress);
    console.log("VaultManager connected to other contracts");

    // 5. CONFIGURING VAULT using VaultManager
    console.log("\n=== CONFIGURING VAULT VIA VAULTMANAGER ===");

    const config = tokenConfig.config;
    await vaultManager.setMaxTotalDeposit(ethers.parseUnits(config.maxTotalDeposit, underlyingTokenDecimals));
    await vaultManager.setMaxUserDeposit(ethers.parseUnits(config.maxDeposit, underlyingTokenDecimals));
    await vaultManager.setFeePercent(config.feePercent);
    await vaultManager.setFloatPercent(config.floatPercent);
    await vaultManager.setCooldownPeriod(config.cooldownPeriod);
    // setMinUnstakeAmount is for the LSToken, which is always 18 decimals
    await vaultManager.setMinUnstakeAmount(ethers.parseEther(config.minDeposit));
    await vaultManager.setStakeEnabled(true);
    await vaultManager.setUnstakeEnabled(true);

    console.log("Vault fully configured and ready for use!");

    // --- SAVE DEPLOYMENT INFO ---
    const output = {
        network: network.name,
        deployer: deployer.address,
        underlyingToken: {
            address: underlyingTokenAddress,
            decimals: underlyingTokenDecimals
        },
        emergencyController: emergencyControllerAddress,
        vaultManager: vaultManagerAddress,
        vault: {
            vault: vaultAddress,
            lsToken: lsTokenAddress,
            silo: siloAddress,
            unstakeManager: unstakeManagerAddress
        },
        implementations: {
            vault: await vaultImpl.getAddress(),
            lsToken: await lsTokenImpl.getAddress(),
            silo: await siloImpl.getAddress(),
            unstakeManager: await unstakeImpl.getAddress()
        },
        status: {
            deployed: true,
            rolesConfigured: true,
            initialized: true,
            readyForUse: true
        }
    };

    const deploymentsDir = path.join(__dirname, '../deployments');
    if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
    const filePath = path.join(deploymentsDir, `${network.name}-${tokenName.toLowerCase()}-deployment.json`);
    fs.writeFileSync(filePath, JSON.stringify(output, null, 2));

    console.log(`DEPLOYMENT COMPLETED! Deployment info saved to: ${filePath}`);
}

main().catch(err => {
    console.error("Deployment failed:", err);
    process.exit(1);
});