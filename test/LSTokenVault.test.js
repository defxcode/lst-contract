const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("LSTokenVault", function () {
    let LSTokenVault, vault, lsToken, underlyingToken, unstakeManager, emergencyController;
    let owner, user1, user2, feeReceiver, custodian1, custodian2;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MANAGER_ROLE"));
    const REWARDER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REWARDER_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

    const ONE_ETHER = ethers.parseEther("1");
    const INITIAL_INDEX = ethers.parseEther("1");

    beforeEach(async function () {
        [owner, user1, user2, feeReceiver, custodian1, custodian2] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        underlyingToken = await MockERC20.deploy("Mock Underlying", "mULT", 18);
        await underlyingToken.waitForDeployment();

        const LSToken = await ethers.getContractFactory("LSToken");
        lsToken = await upgrades.deployProxy(LSToken, ["Test LS Token", "tLST"], { kind: 'uups' });
        await lsToken.waitForDeployment();

        LSTokenVault = await ethers.getContractFactory("LSTokenVault");
        vault = await upgrades.deployProxy(LSTokenVault, [
            await underlyingToken.getAddress(),
            await lsToken.getAddress(),
            "mULT",
            "tLST",
            owner.address
        ], { kind: 'uups' });
        await vault.waitForDeployment();

        const UnstakeManagerMock = await ethers.getContractFactory("UnstakeManager");
        unstakeManager = await upgrades.deployProxy(UnstakeManagerMock, [
            await vault.getAddress(),
            await underlyingToken.getAddress(),
            await lsToken.getAddress(),
            owner.address
        ]);
        await unstakeManager.waitForDeployment();

        const VAULT_ROLE = await unstakeManager.VAULT_ROLE();
        await unstakeManager.grantRole(VAULT_ROLE, await vault.getAddress());

        const EmergencyControllerMock = await ethers.getContractFactory("EmergencyController");
        emergencyController = await upgrades.deployProxy(EmergencyControllerMock, [owner.address]);
        await emergencyController.waitForDeployment();

        await lsToken.grantRole(ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE")), await vault.getAddress());
        await lsToken.grantRole(ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE")), await unstakeManager.getAddress());
        await vault.setUnstakeManager(await unstakeManager.getAddress());
        await vault.setEmergencyController(await emergencyController.getAddress());
        await vault.setFeeReceiver(feeReceiver.address);

        await underlyingToken.mint(user1.address, ethers.parseEther("10000"));
        await underlyingToken.connect(user1).approve(await vault.getAddress(), ethers.parseEther("10000"));
    });

    describe("Initialization", function () {
        it("should set the correct initial values", async function () {
            expect(await vault.underlyingToken()).to.equal(await underlyingToken.getAddress());
            expect(await vault.lsToken()).to.equal(await lsToken.getAddress());
            expect(await vault.lastIndex()).to.equal(INITIAL_INDEX);
            expect(await vault.targetIndex()).to.equal(INITIAL_INDEX);
            expect(await vault.stakeEnabled()).to.be.true;
        });

        it("should grant all roles to the initial admin", async function () {
            expect(await vault.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
            expect(await vault.hasRole(MANAGER_ROLE, owner.address)).to.be.true;
            expect(await vault.hasRole(REWARDER_ROLE, owner.address)).to.be.true;
            expect(await vault.hasRole(EMERGENCY_ROLE, owner.address)).to.be.true;
        });
    });

    describe("deposit", function () {
        it("should allow a user to deposit and mint lsTokens at a 1:1 ratio initially", async function () {
            await expect(vault.connect(user1).deposit(ethers.parseEther("100")))
                .to.emit(vault, "Deposited")
                .withArgs(user1.address, ethers.parseEther("100"), ethers.parseEther("100"));

            expect(await lsToken.balanceOf(user1.address)).to.equal(ethers.parseEther("100"));
            expect(await underlyingToken.balanceOf(await vault.getAddress())).to.equal(ethers.parseEther("100"));
        });

        it("should fail if staking is disabled", async function () {
            await vault.setStakeEnabled(false);
            await expect(vault.connect(user1).deposit(ONE_ETHER)).to.be.revertedWith("Staking disabled");
        });

        it("should fail if the deposit amount is below the minimum", async function () {
            await vault.setMinDepositAmount(ethers.parseEther("1"));
            await expect(vault.connect(user1).deposit(ethers.parseEther("0.5"))).to.be.revertedWith("Below minimum");
        });

        it("should fail if the global deposit limit is reached", async function () {
            await vault.setMaxTotalDeposit(ethers.parseEther("99"));
            await expect(vault.connect(user1).deposit(ethers.parseEther("100"))).to.be.revertedWith("Global limit reached");
        });

        it("should enforce the user deposit limit", async function () {
            await vault.setMaxUserDeposit(ethers.parseEther("500"));
            await vault.connect(user1).deposit(ethers.parseEther("300"));
            await expect(vault.connect(user1).deposit(ethers.parseEther("201"))).to.be.revertedWith("User limit reached");
        });
    });

    describe("addYield", function () {
        beforeEach(async function() {
            await vault.connect(user1).deposit(ethers.parseEther("1000"));
            await vault.grantRole(REWARDER_ROLE, owner.address);
            await underlyingToken.mint(owner.address, ethers.parseEther("100"));
            await underlyingToken.connect(owner).approve(await vault.getAddress(), ethers.parseEther("100"));
            await vault.setFlashLoanProtection(1000); // 10%
        });

        it("should correctly calculate fees and increase the targetIndex", async function () {
            await vault.setFeePercent(10);
            await vault.addYield(ethers.parseEther("100"));
            expect(await vault.totalFeeCollected()).to.equal(ethers.parseEther("10"));
            const expectedTargetIndex = ethers.parseEther("1.09");
            expect(await vault.targetIndex()).to.equal(expectedTargetIndex);
        });

        it("should fail if yield is vesting", async function () {
            await vault.addYield(ethers.parseEther("10"));
            await expect(vault.addYield(ethers.parseEther("10"))).to.be.revertedWith("Previous yield vesting");
        });

        it("should vest the index linearly over time", async function () {
            await vault.setFeePercent(10);
            await vault.addYield(ethers.parseEther("80"));

            expect(await vault.getCurrentIndex()).to.equal(INITIAL_INDEX);

            const VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(VESTING_DURATION) / 2);

            expect(await vault.getCurrentIndex()).to.be.closeTo(ethers.parseEther("1.036"), ethers.parseEther("0.0001"));
        });
    });

    describe("requestUnstake", function () {
        beforeEach(async function() {
            await vault.connect(user1).deposit(ethers.parseEther("1000"));
            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.parseEther("1000"));
        });

        it("should fail if the withdrawal lock is active", async function () {
            await expect(vault.connect(user1)["requestUnstake(uint256)"](ethers.parseEther("100")))
                .to.be.revertedWith("Withdrawal lock active");
        });

        it("should successfully request an unstake after the lock expires", async function () {
            const VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(VESTING_DURATION) + 1);

            await expect(vault.connect(user1)["requestUnstake(uint256)"](ethers.parseEther("100")))
                .to.not.be.reverted;
        });
    });

    describe("Forfeited Yield (Early Unstake)", function () {
        beforeEach(async function() {
            // User 1 deposits 1000 underlying tokens
            await vault.connect(user1).deposit(ethers.parseEther("1000"));

            // Grant REWARDER_ROLE and mint yield tokens for the owner
            await vault.grantRole(REWARDER_ROLE, owner.address);
            await underlyingToken.mint(owner.address, ethers.parseEther("200"));
            await underlyingToken.connect(owner).approve(await vault.getAddress(), ethers.parseEther("200"));
            await vault.setFlashLoanProtection(1000); // 10%
            await vault.setFeePercent(10); // 10% fee
        });

        it("should redirect forfeited yield from an early unstake directly to protocol fees", async function () {
            // 1. Add yield to start a vesting period
            await vault.addYield(ethers.parseEther("100")); // 10% fee means 90 goes to yield

            // After this, targetIndex will be 1 + (90 / 1000) = 1.09
            const targetIndex = await vault.targetIndex();
            expect(targetIndex).to.equal(ethers.parseEther("1.09"));

            // 2. Increase time by half the vesting duration
            const VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(VESTING_DURATION) / 2);

            // Current index should be halfway, around 1.045
            const currentIndex = await vault.getCurrentIndex();
            expect(currentIndex).to.be.closeTo(ethers.parseEther("1.045"), ethers.parseEther("0.0001"));

            // 3. User 1 requests to unstake their full amount during the vesting period
            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.parseEther("1000"));

            const initialFees = await vault.totalFeeCollected(); // Should be 10 ether from the yield fee
            expect(initialFees).to.equal(ethers.parseEther("10"));

            await expect(vault.connect(user1)["requestUnstake(uint256)"](ethers.parseEther("1000")))
                .to.emit(vault, "FeesCollected");

            // 4. Calculate forfeited amount and check if it was added to fees
            // Value at target index = 1000 * 1.09 = 1090
            const targetValue = ethers.parseEther("1090");
            // Value at current index = 1000 * ~1.045 = ~1045
            const currentValue = await vault.previewRedeem(ethers.parseEther("1000"));
            const forfeitedAmount = targetValue - currentValue;
            const finalFees = await vault.totalFeeCollected();

            // Final fees = initial 10 ether fee + forfeited amount
            expect(finalFees).to.be.closeTo(initialFees + forfeitedAmount, ethers.parseEther("0.0001"));

            // 5. Ensure the forfeited amount is not redistributed in the next yield cycle
            // Wait for the initial vesting to finish
            await time.increase(Number(VESTING_DURATION));

            // User2 deposits to provide supply for the next yield addition
            await underlyingToken.mint(user2.address, ethers.parseEther("1000"));
            await underlyingToken.connect(user2).approve(await vault.getAddress(), ethers.parseEther("1000"));
            await vault.connect(user2).deposit(ethers.parseEther("1000"));

            const oldTargetIndex = await vault.targetIndex();

            // Add another 100 yield
            await vault.addYield(ethers.parseEther("100"));

            const newTargetIndex = await vault.targetIndex();
            const newTotalSupply = await lsToken.totalSupply(); // approx 1000 lsTokens for user2
            const yieldAdded = ethers.parseEther("90"); // 100 yield - 10% fee

            // The change in index should only reflect the new yield, not the old forfeited amount.
            // deltaIndex = (yieldAdded * 1e18) / newTotalSupply
            const deltaIndex = (yieldAdded * ethers.parseEther("1")) / newTotalSupply;

            expect(newTargetIndex).to.be.closeTo(oldTargetIndex + deltaIndex, ethers.parseEther("0.0001"));
        });
    });

    describe("Custodian Management", function () {
        it("should allow an admin to add, update, and remove custodians", async function () {
            await vault.addCustodian(custodian1.address, 40);
            let [wallets, allocations] = await vault.getAllCustodians();
            expect(wallets[0]).to.equal(custodian1.address);
            expect(allocations[0]).to.equal(40);

            await vault.updateCustodian(0, custodian2.address, 50);
            [wallets, allocations] = await vault.getAllCustodians();
            expect(wallets[0]).to.equal(custodian2.address);
            expect(allocations[0]).to.equal(50);

            await vault.addCustodian(custodian1.address, 20);
            await vault.removeCustodian(0);
            [wallets, allocations] = await vault.getAllCustodians();
            expect(wallets.length).to.equal(1);
            expect(wallets[0]).to.equal(custodian1.address);
        });

        it("should prevent total allocation from exceeding 100%", async function () {
            await vault.addCustodian(custodian1.address, 50);
            await vault.setFloatPercent(50);
            await expect(vault.addCustodian(custodian2.address, 1)).to.be.revertedWith("Total allocation + float cannot exceed 100%");
        });
    });

    describe("Emergency Pause", function () {
        it("should prevent deposits when paused by admin", async function () {
            await vault.pause();
            await expect(vault.connect(user1).deposit(ONE_ETHER)).to.be.revertedWith("Pausable: paused");
        });

        it("should prevent deposits when deposits are paused by the EmergencyController", async function () {
            await emergencyController.pauseDeposits();
            await expect(vault.connect(user1).deposit(ONE_ETHER)).to.be.revertedWith("Deposits paused");
        });
    });

    describe("Input Validation and Edge Cases", function () {
        it("should revert when trying to add zero yield", async function () {
            await vault.connect(user1).deposit(ethers.parseEther("100"));
            await vault.grantRole(REWARDER_ROLE, owner.address);
            await expect(vault.addYield(0)).to.be.revertedWith("Yield must be > 0");
        });

        it("should revert if yield is too low to register an index change", async function () {
            await vault.setRateLimits(ethers.parseEther("1000000"), ethers.parseEther("1000000"));
            await vault.setMaxUserDeposit(ethers.parseEther("1000000"));
            await underlyingToken.mint(user1.address, ethers.parseEther("1000000"));
            await underlyingToken.connect(user1).approve(await vault.getAddress(), ethers.parseEther("1000000"));
            await vault.connect(user1).deposit(ethers.parseEther("1000000"));

            await vault.grantRole(REWARDER_ROLE, owner.address);
            await underlyingToken.mint(owner.address, 1);
            await underlyingToken.approve(await vault.getAddress(), 1);

            await expect(vault.addYield(1)).to.be.revertedWith("Yield too low to register");
        });
    });
});
