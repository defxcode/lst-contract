const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("UnstakeManager", function () {
    let UnstakeManager, unstakeManager, lsToken, underlyingToken, vault, silo, emergencyController;
    let owner, user1, user2, user3, manager;

    const VAULT_ROLE = ethers.keccak256(ethers.toUtf8Bytes("VAULT_ROLE"));
    const MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MANAGER_ROLE"));
    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));

    const ONE_ETHER = ethers.parseEther("1");
    const INITIAL_INDEX = ethers.parseEther("1");
    beforeEach(async function () {
        [owner, user1, user2, user3, manager] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        underlyingToken = await MockERC20.deploy("Mock Underlying", "mULT", 18);
        await underlyingToken.waitForDeployment();

        const LSToken = await ethers.getContractFactory("LSToken");
        lsToken = await upgrades.deployProxy(LSToken, ["Test LS Token", "tLST"]);
        await lsToken.waitForDeployment();

        const EmergencyControllerMock = await ethers.getContractFactory("EmergencyController");
        emergencyController = await upgrades.deployProxy(EmergencyControllerMock, [owner.address]);
        await emergencyController.waitForDeployment();

        const LSTokenVault = await ethers.getContractFactory("LSTokenVault");
        vault = await upgrades.deployProxy(LSTokenVault, [
            await underlyingToken.getAddress(),
            await lsToken.getAddress(),
            "mULT",
            "tLST",
            owner.address
        ], { kind: 'uups' });
        await vault.waitForDeployment();
        await vault.setEmergencyController(await emergencyController.getAddress());

        const TokenSilo = await ethers.getContractFactory("TokenSilo");
        silo = await upgrades.deployProxy(TokenSilo, [
            await underlyingToken.getAddress(),
            "mULT",
            owner.address,
            owner.address
        ], { kind: 'uups', initializer: 'initialize(address,string,address,address)' });
        await silo.waitForDeployment();


        UnstakeManager = await ethers.getContractFactory("UnstakeManager");
        unstakeManager = await upgrades.deployProxy(UnstakeManager, [
            await vault.getAddress(),
            await underlyingToken.getAddress(),
            await lsToken.getAddress(),
            await silo.getAddress()
        ]);
        await unstakeManager.waitForDeployment();

        await vault.setUnstakeManager(await unstakeManager.getAddress());

        await unstakeManager.grantRole(ADMIN_ROLE, owner.address);
        await unstakeManager.grantRole(MANAGER_ROLE, manager.address);
        await unstakeManager.grantRole(VAULT_ROLE, await vault.getAddress());


        const MINTER_ROLE = await lsToken.MINTER_ROLE();
        await lsToken.grantRole(MINTER_ROLE, await unstakeManager.getAddress());
        await lsToken.grantRole(MINTER_ROLE, await vault.getAddress());


        await unstakeManager.setEmergencyController(await emergencyController.getAddress());
        const SILO_VAULT_ROLE = await silo.VAULT_ROLE();
        await silo.grantRole(SILO_VAULT_ROLE, await unstakeManager.getAddress());
    });

    describe("Initialization", function () {
        it("should set the correct addresses and grant VAULT_ROLE to the vault", async function () {
            expect(await unstakeManager.vault()).to.equal(await vault.getAddress());
            expect(await unstakeManager.underlyingToken()).to.equal(await underlyingToken.getAddress());
            expect(await unstakeManager.lsToken()).to.equal(await lsToken.getAddress());
            expect(await unstakeManager.silo()).to.equal(await silo.getAddress());
            expect(await unstakeManager.hasRole(VAULT_ROLE, await vault.getAddress())).to.be.true;
        });

        it("should set default configuration values", async function () {
            expect(await unstakeManager.cooldownPeriod()).to.equal(7 * 24 * 60 * 60);
            expect(await unstakeManager.minUnstakeAmount()).to.equal(ethers.parseEther("0.1"));
        });
    });

    describe("Unstake Request Lifecycle", function () {
        beforeEach(async function() {
            await underlyingToken.mint(user1.address, ethers.parseEther("1000"));
            await underlyingToken.connect(user1).approve(await vault.getAddress(), ethers.parseEther("1000"));
            await vault.connect(user1).deposit(ethers.parseEther("1000"));

            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.parseEther("1000"));

            await underlyingToken.mint(await vault.getAddress(), ethers.parseEther("2000"));
            await vault.approveUnstakeManager(ethers.parseEther("2000"));

            const YIELD_VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(YIELD_VESTING_DURATION) + 1);
        });

        it("Step 1: requestUnstake - should create a request and burn lsTokens", async function () {
            const blockTime = await time.latest();
            await expect(vault.connect(user1)["requestUnstake(uint256,uint256)"](ethers.parseEther("100"), 0))
                .to.emit(unstakeManager, "UnstakeRequested")
                .withArgs(user1.address, ethers.parseEther("100"), (val) => val > blockTime, 1);

            expect(await lsToken.balanceOf(user1.address)).to.equal(ethers.parseEther("900"));

            const [status, amount] = await unstakeManager.getRequestInfo(user1.address);
            expect(status).to.equal(1);
            expect(amount).to.equal(ethers.parseEther("100"));
        });

        it("Step 2: markRequestsForProcessing - should change request status to PROCESSING", async function () {
            await vault.connect(user1)["requestUnstake(uint256,uint256)"](ONE_ETHER, 0);

            await expect(unstakeManager.connect(manager).markRequestsForProcessing([1]))
                .to.emit(unstakeManager, "UnstakeStatusChanged")
                .withArgs(user1.address, 2, 1);

            const [status] = await unstakeManager.getRequestInfo(user1.address);
            expect(status).to.equal(2);
        });

        it("Step 3 & 4: processUserUnstake & claim - full flow for a single user", async function () {
            await vault.connect(user1)["requestUnstake(uint256,uint256)"](ethers.parseEther("50"), 0);

            await expect(unstakeManager.connect(manager).processUserUnstake(user1.address))
                .to.emit(unstakeManager, "UnstakeProcessed");

            const [status] = await unstakeManager.getRequestInfo(user1.address);
            expect(status).to.equal(3);

            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(unstakeManager.connect(user1).claim(user1.address))
                .to.emit(unstakeManager, "Claimed");

            const [finalStatus] = await unstakeManager.getRequestInfo(user1.address);
            expect(finalStatus).to.equal(0);
        });

        it("should fail to claim before the cooldown period ends", async function () {
            await vault.connect(user1)["requestUnstake(uint256,uint256)"](ONE_ETHER, 0);
            await unstakeManager.connect(manager).processUserUnstake(user1.address);

            await expect(unstakeManager.connect(user1).claim(user1.address))
                .to.be.revertedWith("UnstakeManager: cooldown not finished");
        });
    });

    describe("Admin and Manager Functions", function () {
        it("should allow a manager to cancel an unstake request", async function () {
            await underlyingToken.mint(user1.address, ethers.parseEther("100"));
            await underlyingToken.connect(user1).approve(await vault.getAddress(), ethers.parseEther("100"));
            await vault.connect(user1).deposit(ethers.parseEther("100"));

            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.parseEther("100"));

            const YIELD_VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(YIELD_VESTING_DURATION) + 1);

            await vault.connect(user1)["requestUnstake(uint256,uint256)"](ethers.parseEther("100"), 0);

            const initialBalance = await lsToken.balanceOf(user1.address);

            await unstakeManager.connect(manager).cancelUnstake(user1.address);

            expect(await lsToken.balanceOf(user1.address)).to.be.gt(initialBalance);
            const [status] = await unstakeManager.getRequestInfo(user1.address);
            expect(status).to.equal(0);
        });

        it("should prevent a manager from canceling an unstake while yield is vesting", async function () {
            // Setup: User 1 and User 2 deposit. This ensures supply never drops to zero.
            await underlyingToken.mint(user1.address, ethers.parseEther("1000"));
            await underlyingToken.connect(user1).approve(await vault.getAddress(), ethers.parseEther("1000"));
            await vault.connect(user1).deposit(ethers.parseEther("1000"));

            await underlyingToken.mint(user2.address, ethers.parseEther("1000"));
            await underlyingToken.connect(user2).approve(await vault.getAddress(), ethers.parseEther("1000"));
            await vault.connect(user2).deposit(ethers.parseEther("1000"));

            const YIELD_VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(YIELD_VESTING_DURATION) + 1); // Expire user1's withdrawal lock

            // User 1 requests to unstake their full amount
            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.MaxUint256);
            await vault.connect(user1)["requestUnstake(uint256)"](ethers.parseEther("1000"));

            // Action: Add yield to start a vesting period. This will now succeed because user2's tokens are still staked.
            await vault.grantRole(await vault.REWARDER_ROLE(), owner.address);
            await underlyingToken.mint(owner.address, ethers.parseEther("100"));
            await underlyingToken.connect(owner).approve(await vault.getAddress(), ethers.parseEther("100"));
            await vault.addYield(ethers.parseEther("100"));

            // Verification: Attempt to cancel during the vesting period
            await expect(
                unstakeManager.connect(manager).cancelUnstake(user1.address)
            ).to.be.revertedWith("UnstakeManager: cannot cancel during vesting");

            // Verification: Cancellation should succeed after the vesting period ends
            await time.increase(Number(YIELD_VESTING_DURATION) + 1);
            await expect(
                unstakeManager.connect(manager).cancelUnstake(user1.address)
            ).to.not.be.reverted;
        });

        it("should allow an admin to set the cooldown period", async function () {
            const newPeriod = 10 * 24 * 60 * 60;
            await unstakeManager.connect(owner).setCooldownPeriod(newPeriod);
            expect(await unstakeManager.cooldownPeriod()).to.equal(newPeriod);
        });

        it("should fail if a non-admin tries to set the cooldown period", async function () {
            await expect(unstakeManager.connect(user1).setCooldownPeriod(123)).to.be.reverted;
        });
    });

    describe("Batch Processing", function () {
        beforeEach(async function() {
            await underlyingToken.mint(user1.address, ethers.parseEther("100"));
            await underlyingToken.mint(user2.address, ethers.parseEther("200"));
            await underlyingToken.mint(user3.address, ethers.parseEther("50"));

            await underlyingToken.connect(user1).approve(await vault.getAddress(), ethers.parseEther("100"));
            await underlyingToken.connect(user2).approve(await vault.getAddress(), ethers.parseEther("200"));
            await underlyingToken.connect(user3).approve(await vault.getAddress(), ethers.parseEther("50"));

            await vault.connect(user1).deposit(ethers.parseEther("100"));
            await vault.connect(user2).deposit(ethers.parseEther("200"));
            await vault.connect(user3).deposit(ethers.parseEther("50"));

            const YIELD_VESTING_DURATION = await vault.YIELD_VESTING_DURATION();
            await time.increase(Number(YIELD_VESTING_DURATION) + 1);

            await lsToken.connect(user1).approve(await unstakeManager.getAddress(), ethers.MaxUint256);
            await lsToken.connect(user2).approve(await unstakeManager.getAddress(), ethers.MaxUint256);
            await lsToken.connect(user3).approve(await unstakeManager.getAddress(), ethers.MaxUint256);

            await vault.connect(user1)["requestUnstake(uint256,uint256)"](ethers.parseEther("50"), 0);
            await vault.connect(user2)["requestUnstake(uint256,uint256)"](ethers.parseEther("100"), 0);
            await vault.connect(user3)["requestUnstake(uint256,uint256)"](ethers.parseEther("25"), 0);
        });

        it("should process requests in batches correctly", async function () {
            await underlyingToken.mint(await vault.getAddress(), ethers.parseEther("175"));
            await vault.approveUnstakeManager(ethers.parseEther("175"));

            await unstakeManager.connect(manager).markRequestsForProcessing([1, 2, 3]);

            // First batch: Process 2 out of 3 requests
            await unstakeManager.connect(manager).processUnstakeQueue(2);

            // Verify state: 1 request should be remaining in the queue
            let [, , queuedCount1, processingCount1] = await unstakeManager.getQueueDetails();
            expect(queuedCount1 + processingCount1).to.equal(1);

            // Second batch: Process the remaining request
            await unstakeManager.connect(manager).processUnstakeQueue(2);

            // Verify state: 0 requests should be remaining in the queue
            let [, , queuedCount2, processingCount2] = await unstakeManager.getQueueDetails();
            expect(queuedCount2 + processingCount2).to.equal(0);
        });
    });
});