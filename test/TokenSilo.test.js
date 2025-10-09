const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("TokenSilo", function () {
    let TokenSilo, silo, underlyingToken, emergencyController;
    let owner, user1, user2, feeCollector, vault;

    const VAULT_ROLE = ethers.keccak256(ethers.toUtf8Bytes("VAULT_ROLE"));
    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));

    beforeEach(async function () {
        [owner, user1, user2, feeCollector, vault] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        underlyingToken = await MockERC20.deploy("Mock Underlying", "mULT", 18);
        await underlyingToken.waitForDeployment();

        const EmergencyControllerMock = await ethers.getContractFactory("EmergencyController");
        emergencyController = await upgrades.deployProxy(EmergencyControllerMock, [owner.address]);
        await emergencyController.waitForDeployment();

        TokenSilo = await ethers.getContractFactory("TokenSilo");
        silo = await upgrades.deployProxy(TokenSilo, [
            await underlyingToken.getAddress(),
            "mULT",
            vault.address,
            feeCollector.address
        ], { kind: 'uups', initializer: 'initialize(address,string,address,address)' });
        await silo.waitForDeployment();

        await silo.grantRole(ADMIN_ROLE, owner.address);
        await silo.setEmergencyController(await emergencyController.getAddress());

        await underlyingToken.mint(vault.address, ethers.parseEther("10000"));
        await underlyingToken.connect(vault).approve(await silo.getAddress(), ethers.parseEther("10000"));
    });

    describe("Initialization", function () {
        it("should set the correct addresses and default config", async function () {
            expect(await silo.underlyingToken()).to.equal(await underlyingToken.getAddress());
            expect(await silo.hasRole(VAULT_ROLE, vault.address)).to.be.true;
            expect(await silo.getFeeCollector()).to.equal(feeCollector.address);
            expect(await silo.getUnlockFee()).to.equal(50);
            expect(await silo.getEarlyUnlockEnabled()).to.be.false;
        });
    });

    describe("Fund Management", function () {
        it("depositFor: should allow the VAULT_ROLE to deposit funds for a user", async function () {
            await expect(silo.connect(vault).depositFor(user1.address, ethers.parseEther("100")))
                .to.emit(silo, "Deposited")
                .withArgs(user1.address, ethers.parseEther("100"));

            expect(await silo.balanceOf(user1.address)).to.equal(ethers.parseEther("100"));
            expect(await silo.getTotalDeposited()).to.equal(ethers.parseEther("100"));
            expect(await underlyingToken.balanceOf(await silo.getAddress())).to.equal(ethers.parseEther("100"));
        });

        it("withdrawTo: should allow the VAULT_ROLE to withdraw funds for a user", async function () {
            await silo.connect(vault).depositFor(user1.address, ethers.parseEther("100"));

            await expect(silo.connect(vault).withdrawTo(user1.address, ethers.parseEther("100")))
                .to.emit(silo, "Withdrawn")
                .withArgs(user1.address, ethers.parseEther("100"));

            expect(await silo.balanceOf(user1.address)).to.equal(0);
            expect(await underlyingToken.balanceOf(user1.address)).to.equal(ethers.parseEther("100"));
        });

        it("should fail to withdraw more than the user's balance", async function () {
            await silo.connect(vault).depositFor(user1.address, ethers.parseEther("100"));
            await expect(silo.connect(vault).withdrawTo(user1.address, ethers.parseEther("101")))
                .to.be.revertedWith("Silo: insufficient user balance");
        });
    });

    describe("Early Withdrawal", function () {
        beforeEach(async function() {
            await silo.setEarlyUnlockEnabled(true);
            await silo.setUnlockFee(500);
            await silo.connect(vault).depositFor(user1.address, ethers.parseEther("200"));
        });

        it("should allow early withdrawal and correctly deduct fees", async function () {
            const initialFeeCollectorBalance = await underlyingToken.balanceOf(feeCollector.address);

            await silo.connect(vault).earlyWithdrawFor(user1.address, ethers.parseEther("200"));

            const expectedFee = ethers.parseEther("10");
            const expectedUserAmount = ethers.parseEther("190");

            expect(await underlyingToken.balanceOf(user1.address)).to.equal(expectedUserAmount);
            expect(await underlyingToken.balanceOf(feeCollector.address)).to.equal(initialFeeCollectorBalance + expectedFee);
            expect(await silo.balanceOf(user1.address)).to.equal(0);
        });

        it("should fail if early withdrawal is not enabled", async function () {
            await silo.setEarlyUnlockEnabled(false);
            await expect(silo.connect(vault).earlyWithdrawFor(user1.address, ethers.parseEther("100")))
                .to.be.revertedWith("Silo: early unlock disabled");
        });
    });

    describe("Security and Liquidity", function () {
        it("should automatically pause claims if liquidity drops below the threshold", async function () {
            await silo.setLiquidityThreshold(8000);

            await silo.connect(vault).depositFor(user1.address, ethers.parseEther("100"));

            await ethers.provider.send("hardhat_impersonateAccount", [await silo.getAddress()]);
            const siloSigner = await ethers.getSigner(await silo.getAddress());
            await ethers.provider.send("hardhat_setBalance", [
                siloSigner.address,
                "0xDE0B6B3A7640000", // 1 ETH in hex
            ]);
            await underlyingToken.connect(siloSigner).transfer(owner.address, ethers.parseEther("21"));
            await ethers.provider.send("hardhat_stopImpersonatingAccount", [await silo.getAddress()]);

            await underlyingToken.connect(vault).approve(await silo.getAddress(), 1);
            await silo.connect(vault).depositFor(user2.address, 1);

            let [, , , isPaused] = await silo.getLiquidityStatus();
            expect(isPaused).to.be.true;

            await expect(silo.connect(vault).withdrawTo(user1.address, ethers.parseEther("1")))
                .to.be.revertedWith("Silo: claims are paused due to liquidity");
        });

        it("should enforce the daily withdrawal rate limit", async function () {
            await silo.setRateLimit(ethers.parseEther("500"));
            await silo.setEarlyUnlockEnabled(true);

            await silo.connect(vault).depositFor(user1.address, ethers.parseEther("400"));
            await silo.connect(vault).depositFor(user2.address, ethers.parseEther("200"));

            await silo.connect(vault).earlyWithdrawFor(user1.address, ethers.parseEther("400"));

            await expect(silo.connect(vault).earlyWithdrawFor(user2.address, ethers.parseEther("200")))
                .to.be.revertedWith("Silo: daily withdrawal limit reached");

            await time.increase(25 * 60 * 60);

            await expect(silo.connect(vault).earlyWithdrawFor(user2.address, ethers.parseEther("200")))
                .to.not.be.reverted;
        });
    });

    describe("Admin Functions", function () {
        it("should allow an admin to change the unlock fee", async function () {
            await silo.setUnlockFee(100);
            expect(await silo.getUnlockFee()).to.equal(100);
        });

        it("should not allow a non-admin to change the unlock fee", async function () {
            await expect(silo.connect(user1).setUnlockFee(100)).to.be.reverted;
        });

        it("should allow an admin to rescue accidentally sent tokens", async function () {
            const SomeOtherToken = await ethers.getContractFactory("MockERC20");
            const otherToken = await SomeOtherToken.deploy("Other Token", "OT", 18);
            await otherToken.waitForDeployment();

            await otherToken.mint(await silo.getAddress(), ethers.parseEther("10"));

            await expect(silo.rescueTokens(await otherToken.getAddress(), owner.address, ethers.parseEther("10")))
                .to.changeTokenBalances(otherToken, [silo, owner], [ethers.parseEther("-10"), ethers.parseEther("10")]);
        });
    });
});