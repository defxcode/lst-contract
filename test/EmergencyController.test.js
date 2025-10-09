const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("EmergencyController", function () {
    let EmergencyController, emergencyController;
    let owner, admin, emergencyRoleHolder, user;

    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

    const RECOVERY_DELAY = 24 * 60 * 60;

    beforeEach(async function () {
        [owner, admin, emergencyRoleHolder, user] = await ethers.getSigners();

        EmergencyController = await ethers.getContractFactory("EmergencyController");
        emergencyController = await upgrades.deployProxy(EmergencyController, [
            admin.address
        ]);
        await emergencyController.waitForDeployment();

        await emergencyController.connect(admin).grantRole(EMERGENCY_ROLE, emergencyRoleHolder.address);
    });

    describe("Initialization", function () {
        it("should set the initial admin correctly and grant all roles", async function () {
            const DEFAULT_ADMIN_ROLE = await emergencyController.DEFAULT_ADMIN_ROLE();
            expect(await emergencyController.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
            expect(await emergencyController.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
            expect(await emergencyController.hasRole(EMERGENCY_ROLE, admin.address)).to.be.true;
        });

        it("should initialize in the 'NORMAL' state", async function () {
            expect(await emergencyController.getEmergencyState()).to.equal(0);
            expect(await emergencyController.recoveryModeActive()).to.be.false;
        });
    });

    describe("System State Control", function () {
        it("pauseDeposits: should allow EMERGENCY_ROLE to pause deposits", async function () {
            await expect(emergencyController.connect(emergencyRoleHolder).pauseDeposits())
                .to.emit(emergencyController, "EmergencyStateChanged").withArgs(1);
            expect(await emergencyController.getEmergencyState()).to.equal(1);
        });

        it("pauseWithdrawals: should allow EMERGENCY_ROLE to pause withdrawals", async function () {
            await expect(emergencyController.connect(emergencyRoleHolder).pauseWithdrawals())
                .to.emit(emergencyController, "EmergencyStateChanged").withArgs(2);
            expect(await emergencyController.getEmergencyState()).to.equal(2);
        });

        it("pauseAll: should allow EMERGENCY_ROLE to pause all operations", async function () {
            await expect(emergencyController.connect(emergencyRoleHolder).pauseAll())
                .to.emit(emergencyController, "EmergencyStateChanged").withArgs(3);
            expect(await emergencyController.getEmergencyState()).to.equal(3);
        });

        it("resumeOperations: should allow ADMIN_ROLE to resume normal operations", async function () {
            await emergencyController.connect(emergencyRoleHolder).pauseAll();
            await expect(emergencyController.connect(admin).resumeOperations())
                .to.emit(emergencyController, "EmergencyStateChanged").withArgs(0);
            expect(await emergencyController.getEmergencyState()).to.equal(0);
        });

        it("should prevent non-authorized roles from changing the state", async function () {
            await expect(emergencyController.connect(user).pauseAll()).to.be.reverted;
            await expect(emergencyController.connect(emergencyRoleHolder).resumeOperations()).to.be.reverted;
        });
    });

    describe("Circuit Breaker and Recovery Mode", function () {
        it("triggerCircuitBreaker: should immediately pause all and schedule recovery mode", async function () {
            await expect(emergencyController.connect(emergencyRoleHolder).triggerCircuitBreaker("Test exploit"))
                .to.emit(emergencyController, "EmergencyCircuitBreakerTriggered");

            expect(await emergencyController.getEmergencyState()).to.equal(3);
            expect(await emergencyController.recoveryModeActivationTime()).to.be.gt(0);
        });

        it("activateRecoveryMode: should fail if called before the timelock expires", async function () {
            await emergencyController.connect(emergencyRoleHolder).triggerCircuitBreaker("Test");
            await expect(emergencyController.connect(emergencyRoleHolder).activateRecoveryMode())
                .to.be.revertedWith("EmergencyController: timelock not expired");
        });

        it("activateRecoveryMode: should succeed after the 24-hour timelock", async function () {
            await emergencyController.connect(emergencyRoleHolder).triggerCircuitBreaker("Test");

            await time.increase(RECOVERY_DELAY + 1);

            await expect(emergencyController.connect(emergencyRoleHolder).activateRecoveryMode())
                .to.emit(emergencyController, "RecoveryModeActivated");

            expect(await emergencyController.recoveryModeActive()).to.be.true;
        });

        it("deactivateRecoveryMode: should allow ADMIN_ROLE to deactivate recovery mode", async function () {
            await emergencyController.connect(emergencyRoleHolder).triggerCircuitBreaker("Test");
            await time.increase(RECOVERY_DELAY + 1);
            await emergencyController.connect(emergencyRoleHolder).activateRecoveryMode();

            await expect(emergencyController.connect(admin).deactivateRecoveryMode())
                .to.emit(emergencyController, "RecoveryModeDeactivated");

            expect(await emergencyController.recoveryModeActive()).to.be.false;
        });

        it("resumeOperations: should fail if recovery mode is active", async function () {
            await emergencyController.connect(emergencyRoleHolder).triggerCircuitBreaker("Test");
            await time.increase(RECOVERY_DELAY + 1);
            await emergencyController.connect(emergencyRoleHolder).activateRecoveryMode();

            await expect(emergencyController.connect(admin).resumeOperations())
                .to.be.revertedWith("EmergencyController: recovery mode active");
        });
    });
});