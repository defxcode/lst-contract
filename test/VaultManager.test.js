const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("VaultManager", function () {
    let VaultManager, vaultManager, mockVault, mockUnstakeManager, mockSilo;
    let owner, admin, manager, user;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MANAGER_ROLE"));

    beforeEach(async function () {
        [owner, admin, manager, user] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const mockUnderlying = await MockERC20.deploy("Mock", "MCK", 18);
        await mockUnderlying.waitForDeployment();
        const mockLSToken = await MockERC20.deploy("Mock LS", "mLS", 18);
        await mockLSToken.waitForDeployment();

        const LSTokenVaultMock = await ethers.getContractFactory("LSTokenVault");
        mockVault = await upgrades.deployProxy(LSTokenVaultMock, [
            await mockUnderlying.getAddress(),
            await mockLSToken.getAddress(),
            "MOCK", "mMock", admin.address
        ]);
        await mockVault.waitForDeployment();

        const TokenSiloMock = await ethers.getContractFactory("TokenSilo");
        mockSilo = await upgrades.deployProxy(TokenSiloMock, [
            await mockUnderlying.getAddress(),
            "MOCK",
            await mockVault.getAddress(),
            admin.address
        ], { initializer: 'initialize(address,string,address,address)' });
        await mockSilo.waitForDeployment();

        const UnstakeManagerMock = await ethers.getContractFactory("UnstakeManager");
        mockUnstakeManager = await upgrades.deployProxy(UnstakeManagerMock, [
            await mockVault.getAddress(),
            await mockUnderlying.getAddress(),
            await mockLSToken.getAddress(),
            await mockSilo.getAddress()
        ]);
        await mockUnstakeManager.waitForDeployment();


        VaultManager = await ethers.getContractFactory("VaultManager");
        vaultManager = await upgrades.deployProxy(VaultManager, [
            await mockVault.getAddress(),
            admin.address
        ]);
        await vaultManager.waitForDeployment();

        await mockVault.connect(admin).grantRole(MANAGER_ROLE, await vaultManager.getAddress());

        await vaultManager.connect(admin).setUnstakeManager(await mockUnstakeManager.getAddress());
        await vaultManager.connect(admin).setTokenSilo(await mockSilo.getAddress());
    });

    describe("Initialization and Setup", function () {
        it("should initialize with the correct vault and admin addresses", async function () {
            expect(await vaultManager.vault()).to.equal(await mockVault.getAddress());
            expect(await vaultManager.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
        });

        it("should allow the admin to set the UnstakeManager and TokenSilo addresses", async function () {
            expect(await vaultManager.unstakeManager()).to.equal(await mockUnstakeManager.getAddress());
            expect(await vaultManager.tokenSilo()).to.equal(await mockSilo.getAddress());
        });

        it("should emit events when setting contract links", async function () {
            await expect(vaultManager.connect(admin).setUnstakeManager(await mockUnstakeManager.getAddress()))
                .to.emit(vaultManager, "UnstakeManagerSet").withArgs(await mockUnstakeManager.getAddress());

            await expect(vaultManager.connect(admin).setTokenSilo(await mockSilo.getAddress()))
                .to.emit(vaultManager, "TokenSiloSet").withArgs(await mockSilo.getAddress());
        });
    });

    describe("Proxied LSTokenVault Functions", function () {
        it("should correctly call setMaxTotalDeposit on the vault", async function () {
            const newMax = ethers.parseEther("5000");
            await vaultManager.connect(admin).setMaxTotalDeposit(newMax);
            expect(await mockVault.maxTotalDeposit()).to.equal(newMax);
        });

        it("should correctly call setFeePercent on the vault", async function () {
            await vaultManager.connect(admin).setFeePercent(15);
            expect(await mockVault.feePercent()).to.equal(15);
        });

        it("should correctly call setStakeEnabled on the vault", async function () {
            await vaultManager.connect(admin).setStakeEnabled(false);
            expect(await mockVault.stakeEnabled()).to.be.false;
        });

        it("should prevent non-admins from calling vault configuration functions", async function () {
            await expect(vaultManager.connect(user).setMaxTotalDeposit(ethers.parseEther("1")))
                .to.be.reverted;
        });
    });

    describe("Proxied UnstakeManager Functions", function () {
        beforeEach(async function() {
            const UM_ADMIN_ROLE = await mockUnstakeManager.ADMIN_ROLE();
            await mockUnstakeManager.connect(owner).grantRole(UM_ADMIN_ROLE, await vaultManager.getAddress());
        });

        it("should correctly call setCooldownPeriod on the UnstakeManager", async function () {
            const newCooldown = 10 * 86400;
            await vaultManager.connect(admin).setCooldownPeriod(newCooldown);
            expect(await mockUnstakeManager.cooldownPeriod()).to.equal(newCooldown);
        });

        it("should correctly call setMinUnstakeAmount on the UnstakeManager", async function () {
            const newMin = ethers.parseEther("0.5");
            await vaultManager.connect(admin).setMinUnstakeAmount(newMin);
            expect(await mockUnstakeManager.minUnstakeAmount()).to.equal(newMin);
        });
    });

    describe("Proxied TokenSilo Functions", function () {
        beforeEach(async function() {
            const TS_ADMIN_ROLE = await mockSilo.ADMIN_ROLE();
            await mockSilo.connect(owner).grantRole(TS_ADMIN_ROLE, await vaultManager.getAddress());
        });

        it("should correctly call setSiloRateLimit on the TokenSilo", async function () {
            const newRateLimit = ethers.parseEther("100000");
            await vaultManager.connect(admin).setSiloRateLimit(newRateLimit);

            const [maxDailyAmount] = await mockSilo.withdrawalLimit();
            expect(maxDailyAmount).to.equal(newRateLimit);
        });
    });

    describe("Manager-Specific Functions", function () {
        beforeEach(async function () {
            await vaultManager.connect(admin).grantRole(MANAGER_ROLE, manager.address);
        });

        it("should allow a manager to call withdrawFees on the vault", async function () {
            await mockVault.connect(admin).setFeeReceiver(manager.address);
            await expect(vaultManager.connect(manager).withdrawFees()).to.be.revertedWith("LSTokenVault: no fees to withdraw");
        });

        it("should prevent a non-manager from calling withdrawFees", async function () {
            await expect(vaultManager.connect(user).withdrawFees()).to.be.reverted;
        });
    });
});