const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

// A comprehensive integration test suite for the entire Liquid Staking Protocol
describe("Protocol Integration Tests", function () {
    // === Test Suite Setup ===
    let underlyingToken, lsToken, vault, unstakeManager, silo, vaultManager, emergencyController;
    let owner, admin, manager, user1, user2, feeReceiver;

    beforeEach(async function () {
        [owner, admin, manager, user1, user2, feeReceiver] = await ethers.getSigners();

        // --- 1. Deploy All Contracts ---
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        underlyingToken = await MockERC20.deploy("Mock Underlying", "mULT", 18);
        await underlyingToken.waitForDeployment();

        const LSToken = await ethers.getContractFactory("LSToken");
        lsToken = await upgrades.deployProxy(LSToken, ["Defx Staked Token", "dxT"], { kind: 'uups' });
        await lsToken.waitForDeployment();

        const LSTokenVault = await ethers.getContractFactory("LSTokenVault");
        vault = await upgrades.deployProxy(LSTokenVault, [await underlyingToken.getAddress(), await lsToken.getAddress(), "mULT", "dxT", admin.address], { kind: 'uups' });
        await vault.waitForDeployment();

        const TokenSilo = await ethers.getContractFactory("TokenSilo");
        silo = await upgrades.deployProxy(TokenSilo, [await underlyingToken.getAddress(), "mULT", owner.address, feeReceiver.address], { kind: 'uups', initializer: 'initialize(address,string,address,address)' });
        await silo.waitForDeployment();

        const UnstakeManager = await ethers.getContractFactory("UnstakeManager");
        unstakeManager = await upgrades.deployProxy(UnstakeManager, [await vault.getAddress(), await underlyingToken.getAddress(), await lsToken.getAddress(), await silo.getAddress()], { kind: 'uups' });
        await unstakeManager.waitForDeployment();

        const VaultManager = await ethers.getContractFactory("VaultManager");
        vaultManager = await upgrades.deployProxy(VaultManager, [await vault.getAddress(), admin.address], { kind: 'uups' });
        await vaultManager.waitForDeployment();

        const EmergencyController = await ethers.getContractFactory("EmergencyController");
        emergencyController = await upgrades.deployProxy(EmergencyController, [admin.address], { kind: 'uups' });
        await emergencyController.waitForDeployment();

        // --- 2. Configure Roles and Connections ---
        const MINTER_ROLE = await lsToken.MINTER_ROLE();
        await lsToken.connect(owner).grantRole(MINTER_ROLE, await vault.getAddress());
        await lsToken.connect(owner).grantRole(MINTER_ROLE, await unstakeManager.getAddress());

        const VAULT_ROLE_SILO = await silo.VAULT_ROLE();
        await silo.connect(owner).grantRole(VAULT_ROLE_SILO, await unstakeManager.getAddress());

        const VAULT_ROLE_UM = await unstakeManager.VAULT_ROLE();
        await unstakeManager.connect(owner).grantRole(VAULT_ROLE_UM, await vault.getAddress());

        const MANAGER_ROLE = await vault.MANAGER_ROLE();
        await vault.connect(admin).grantRole(MANAGER_ROLE, await vaultManager.getAddress());

        const ADMIN_ROLE_UM = await unstakeManager.ADMIN_ROLE();
        await unstakeManager.connect(owner).grantRole(ADMIN_ROLE_UM, await vaultManager.getAddress());
        await unstakeManager.connect(owner).grantRole(ADMIN_ROLE_UM, admin.address);

        const ADMIN_ROLE_SILO = await silo.ADMIN_ROLE();
        await silo.connect(owner).grantRole(ADMIN_ROLE_SILO, await vaultManager.getAddress());

        await vault.connect(admin).setUnstakeManager(await unstakeManager.getAddress());
        await vault.connect(admin).setEmergencyController(await emergencyController.getAddress());
        await unstakeManager.connect(admin).setEmergencyController(await emergencyController.getAddress());
        await silo.connect(owner).setEmergencyController(await emergencyController.getAddress());

        await vaultManager.connect(admin).setUnstakeManager(await unstakeManager.getAddress());
        await vaultManager.connect(admin).setTokenSilo(await silo.getAddress());

        // --- 3. Final Preparations ---
        await vault.connect(admin).approveUnstakeManager(ethers.MaxUint256);
        await unstakeManager.connect(owner).grantRole(await unstakeManager.MANAGER_ROLE(), manager.address);

        await underlyingToken.mint(user1.address, ethers.parseEther("1000"));
        await underlyingToken.connect(user1).approve(await vault.getAddress(), ethers.parseEther("1000"));
    });

    // === Full Staking and Unstaking Flow ===
    describe("Happy Path: Full Staking and Unstaking Flow", function () {
        it("should allow a user to deposit, earn yield, unstake, and claim successfully", async function () {
            await vault.connect(user1).deposit(ethers.parseEther("1000"));
            await vault.connect(admin).setFlashLoanProtection(1000); // 10%
            await vault.connect(admin).grantRole(await vault.REWARDER_ROLE(), owner.address);
            await underlyingToken.mint(owner.address, ethers.parseEther("100"));
            await underlyingToken.connect(owner).approve(await vault.getAddress(), ethers.parseEther("100"));
            await vault.connect(owner).addYield(ethers.parseEther("100"));
            await time.increase(8 * 3600 + 1);
            const YIELD_VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(YIELD_VESTING_DURATION) + 1);
            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.MaxUint256);
            await vault.connect(user1)["requestUnstake(uint256)"](ethers.parseEther("1000"));
            await underlyingToken.mint(await vault.getAddress(), ethers.parseEther("1100"));
            await unstakeManager.connect(manager).processUserUnstake(user1.address);
            await time.increase(7 * 24 * 3600 + 1);
            const initialBalance = await underlyingToken.balanceOf(user1.address);
            await unstakeManager.connect(user1).claim(user1.address);
            const finalBalance = await underlyingToken.balanceOf(user1.address);
            const expectedGain = ethers.parseEther("1090");
            expect(finalBalance - initialBalance).to.be.closeTo(expectedGain, ethers.parseEther("0.1"));
        });
    });

    // === Early Withdrawal Flow ===
    describe("Early Withdrawal Flow", function () {
        it("should allow a user to unstake and withdraw early for a fee", async function () {
            await vault.connect(user1).deposit(ethers.parseEther("500"));
            const YIELD_VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(YIELD_VESTING_DURATION) + 1);
            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.MaxUint256);
            await vault.connect(user1)["requestUnstake(uint256)"](ethers.parseEther("500"));
            await underlyingToken.mint(await vault.getAddress(), ethers.parseEther("500"));
            await unstakeManager.connect(manager).processUserUnstake(user1.address);
            await silo.connect(owner).setEarlyUnlockEnabled(true);
            await silo.connect(owner).setUnlockFee(200);
            const userBalanceBefore = await underlyingToken.balanceOf(user1.address);
            const feeCollectorBalanceBefore = await underlyingToken.balanceOf(feeReceiver.address);
            await unstakeManager.connect(user1).earlyWithdraw();
            const userBalanceAfter = await underlyingToken.balanceOf(user1.address);
            const feeCollectorBalanceAfter = await underlyingToken.balanceOf(feeReceiver.address);
            const expectedFee = ethers.parseEther("10");
            const expectedUserAmount = ethers.parseEther("490");
            expect(userBalanceAfter - userBalanceBefore).to.equal(expectedUserAmount);
            expect(feeCollectorBalanceAfter - feeCollectorBalanceBefore).to.equal(expectedFee);
        });
    });

    // === Emergency Scenario ===
    describe("Emergency Scenario", function () {
        it("should block deposits and withdrawals when Circuit Breaker is triggered", async function () {
            await emergencyController.connect(admin).grantRole(await emergencyController.EMERGENCY_ROLE(), manager.address);
            await emergencyController.connect(manager).triggerCircuitBreaker("System compromise detected");
            await expect(vault.connect(user1).deposit(ethers.parseEther("100"))).to.be.revertedWith("Deposits paused");
            await emergencyController.connect(admin).deactivateRecoveryMode();
            await emergencyController.connect(admin).resumeOperations();
            await vault.connect(user1).deposit(ethers.parseEther("100"));
            await time.increase(Number(await vault.YIELD_VESTING_DURATION()) + 1);
            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.MaxUint256);
            await emergencyController.connect(manager).triggerCircuitBreaker("Restarting test");
            await expect(vault.connect(user1)["requestUnstake(uint256)"](ethers.parseEther("100"))).to.be.revertedWith("Withdrawals paused");
        });
    });

    // === Complex State Interaction Scenario ===
    describe("Complex State Interaction", function() {
        it("should correctly value an unstake request made before a large yield event", async function () {
            await vault.connect(user1).deposit(ethers.parseEther("1000"));
            const YIELD_VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(YIELD_VESTING_DURATION) + 1);
            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.MaxUint256);
            await vault.connect(user1)["requestUnstake(uint256)"](ethers.parseEther("1000"));
            const [, underlyingAmountOwed] = await unstakeManager.getRequestInfo(user1.address);
            expect(underlyingAmountOwed).to.equal(ethers.parseEther("1000"));

            await underlyingToken.mint(user2.address, ethers.parseEther("1000"));
            await underlyingToken.connect(user2).approve(await vault.getAddress(), ethers.parseEther("1000"));
            await vault.connect(user2).deposit(ethers.parseEther("1000"));

            await underlyingToken.mint(owner.address, ethers.parseEther("100"));
            await underlyingToken.connect(owner).approve(await vault.getAddress(), ethers.parseEther("100"));
            await vault.connect(admin).grantRole(await vault.REWARDER_ROLE(), owner.address);
            await vault.connect(admin).setFlashLoanProtection(2000);
            await vault.connect(owner).addYield(ethers.parseEther("100"));
            await time.increase(8 * 3600);
            await underlyingToken.mint(await vault.getAddress(), ethers.parseEther("1000"));
            await unstakeManager.connect(manager).processUserUnstake(user1.address);
            await time.increase(7 * 24 * 3600);
            const balanceBeforeClaim = await underlyingToken.balanceOf(user1.address);
            await unstakeManager.connect(user1).claim(user1.address);
            const balanceAfterClaim = await underlyingToken.balanceOf(user1.address);
            expect(balanceAfterClaim - balanceBeforeClaim).to.equal(ethers.parseEther("1000"));
        });
    });
});