const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("LSToken", function () {
    let LSToken, lsToken;
    let owner, addr1, addr2, vault;

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const UPGRADE_TIMELOCK = 2 * 24 * 60 * 60;

    beforeEach(async function () {
        [owner, addr1, addr2, vault] = await ethers.getSigners();
        LSToken = await ethers.getContractFactory("LSToken");
        lsToken = await upgrades.deployProxy(LSToken, ["Defx Staked rETH", "drETH"], { kind: 'uups' });
        await lsToken.waitForDeployment();
    });

    describe("Initialization", function () {
        it("should deploy successfully and set the correct name and symbol", async function () {
            expect(await lsToken.name()).to.equal("Defx Staked rETH");
            expect(await lsToken.symbol()).to.equal("drETH");
        });

        it("should grant DEFAULT_ADMIN_ROLE and ADMIN_ROLE to the deployer", async function () {
            const DEFAULT_ADMIN_ROLE = await lsToken.DEFAULT_ADMIN_ROLE();
            expect(await lsToken.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
            expect(await lsToken.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
        });

        it("should set the initial contract version to 1", async function () {
            expect(await lsToken.version()).to.equal(1);
        });

        it("should initialize with zero total supply", async function () {
            expect(await lsToken.totalSupply()).to.equal(0);
        });
    });

    describe("ERC20 Functionality", function () {
        beforeEach(async function () {
            await lsToken.grantRole(MINTER_ROLE, vault.address);
            await lsToken.connect(vault).mint(addr1.address, ethers.parseEther("1000"));
        });

        it("should correctly return 18 decimals", async function () {
            expect(await lsToken.decimals()).to.equal(18);
        });

        context("Transfers", function () {
            it("should transfer tokens between accounts", async function () {
                await expect(lsToken.connect(addr1).transfer(addr2.address, ethers.parseEther("200")))
                    .to.changeTokenBalances(lsToken, [addr1, addr2], [ethers.parseEther("-200"), ethers.parseEther("200")]);
            });

            it("should fail to transfer more tokens than the sender's balance", async function () {
                await expect(lsToken.connect(addr1).transfer(addr2.address, ethers.parseEther("1001")))
                    .to.be.revertedWith("ERC20: transfer amount exceeds balance");
            });

            it("should fail to transfer tokens to the zero address", async function () {
                await expect(lsToken.connect(addr1).transfer(ethers.ZeroAddress, ethers.parseEther("100")))
                    .to.be.revertedWith("ERC20: transfer to the zero address");
            });
        });

        context("Allowances and transferFrom", function () {
            it("should correctly approve an allowance", async function () {
                await lsToken.connect(addr1).approve(addr2.address, ethers.parseEther("150"));
                expect(await lsToken.allowance(addr1.address, addr2.address)).to.equal(ethers.parseEther("150"));
            });

            it("should allow a spender to transfer tokens on behalf of the owner", async function () {
                await lsToken.connect(addr1).approve(owner.address, ethers.parseEther("300"));
                await expect(lsToken.connect(owner).transferFrom(addr1.address, addr2.address, ethers.parseEther("300")))
                    .to.changeTokenBalances(lsToken, [addr1, addr2], [ethers.parseEther("-300"), ethers.parseEther("300")]);
            });

            it("should fail if the transferFrom amount exceeds the allowance", async function () {
                await lsToken.connect(addr1).approve(owner.address, ethers.parseEther("299"));
                await expect(lsToken.connect(owner).transferFrom(addr1.address, addr2.address, ethers.parseEther("300")))
                    .to.be.revertedWith("ERC20: insufficient allowance");
            });
        });
    });

    describe("Access Control: Minting and Burning", function () {
        context("Minting", function () {
            it("should allow an account with MINTER_ROLE to mint tokens", async function () {
                await lsToken.grantRole(MINTER_ROLE, vault.address);
                await expect(lsToken.connect(vault).mint(addr1.address, ethers.parseEther("500")))
                    .to.changeTokenBalance(lsToken, addr1, ethers.parseEther("500"));
                expect(await lsToken.totalSupply()).to.equal(ethers.parseEther("500"));
            });

            it("should fail if an account without MINTER_ROLE tries to mint", async function () {
                await expect(lsToken.connect(addr1).mint(addr1.address, ethers.parseEther("500")))
                    .to.be.reverted;
            });

            it("should fail to mint to the zero address", async function () {
                await lsToken.grantRole(MINTER_ROLE, vault.address);
                await expect(lsToken.connect(vault).mint(ethers.ZeroAddress, ethers.parseEther("500")))
                    .to.be.revertedWith("LSToken: cannot mint to zero address");
            });
        });

        context("Burning", function () {
            beforeEach(async function () {
                await lsToken.grantRole(MINTER_ROLE, vault.address);
                await lsToken.connect(vault).mint(addr1.address, ethers.parseEther("1000"));
            });

            it("should allow an account with MINTER_ROLE to burn tokens from another account with allowance", async function () {
                await lsToken.connect(addr1).approve(vault.address, ethers.parseEther("400"));

                await expect(lsToken.connect(vault).burnFrom(addr1.address, ethers.parseEther("400")))
                    .to.changeTokenBalance(lsToken, addr1, ethers.parseEther("-400"));
                expect(await lsToken.totalSupply()).to.equal(ethers.parseEther("600"));
            });

            it("should fail if an account without MINTER_ROLE tries to burn", async function () {
                await lsToken.connect(addr1).approve(addr2.address, ethers.parseEther("400"));
                await expect(lsToken.connect(addr2).burnFrom(addr1.address, ethers.parseEther("400")))
                    .to.be.reverted;
            });

            it("should fail to burn without a sufficient allowance", async function () {
                await lsToken.connect(addr1).approve(vault.address, ethers.parseEther("399"));
                await expect(lsToken.connect(vault).burnFrom(addr1.address, ethers.parseEther("400")))
                    .to.be.revertedWith("ERC20: insufficient allowance");
            });
        });
    });

    describe("Upgradeability", function () {
        it("should allow an admin to request an upgrade", async function () {
            await expect(lsToken.requestUpgrade())
                .to.emit(lsToken, "UpgradeRequested");
            const [, requestTime] = await lsToken.upgradeRequested();
            expect(requestTime).to.be.gt(0);
        });

        it("should not allow a non-admin to request an upgrade", async function () {
            await expect(lsToken.connect(addr1).requestUpgrade()).to.be.reverted;
        });

        it("should allow an admin to cancel an upgrade", async function () {
            await lsToken.requestUpgrade();
            await expect(lsToken.cancelUpgrade()).to.emit(lsToken, "UpgradeCancelled");
            const [requested, ] = await lsToken.upgradeRequested();
            expect(requested).to.be.false;
        });

        it("should fail to upgrade before the timelock expires", async function () {
            await lsToken.requestUpgrade();
            const LSTokenV2 = await ethers.getContractFactory("LSToken");
            await expect(upgrades.upgradeProxy(await lsToken.getAddress(), LSTokenV2))
                .to.be.revertedWith("LSToken: timelock not expired");
        });

        it("should successfully upgrade after the timelock period", async function () {
            await lsToken.requestUpgrade();

            await time.increase(UPGRADE_TIMELOCK + 1);

            const LSTokenV2 = await ethers.getContractFactory("LSToken");
            const lsTokenAddress = await lsToken.getAddress();
            const lsTokenV2 = await upgrades.upgradeProxy(lsTokenAddress, LSTokenV2);

            expect(await lsTokenV2.getAddress()).to.equal(lsTokenAddress);
            expect(await lsTokenV2.version()).to.equal(2);
        });
    });
});