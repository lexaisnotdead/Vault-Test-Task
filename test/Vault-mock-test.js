const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("Vault", function () {
    let Vault, vault, owner, fundManager, Alice, Bob, BadActor, TestToken, depositToken, tokenA, tokenB, MockProtocol, mockProtocol;

    before(async function () {
        [owner, fundManager, Alice, Bob, BadActor] = await ethers.getSigners();

        Vault = await ethers.getContractFactory("Vault");
        TestToken = await ethers.getContractFactory("TestERC20");
        MockProtocol = await ethers.getContractFactory("MockProtocol");
    });

    beforeEach(async function() {
        depositToken = await TestToken.deploy("Deposit Token", "DPSTKN");
        await depositToken.waitForDeployment();

        tokenA = await TestToken.deploy("Token A", "TKNA");
        await tokenA.waitForDeployment();

        tokenB = await TestToken.deploy("Token B", "TKNB");
        await tokenB.waitForDeployment();

        mockProtocol = await MockProtocol.deploy();
        await mockProtocol.waitForDeployment();

        vault = await upgrades.deployProxy(
            Vault,
            [depositToken.target, mockProtocol.target, mockProtocol.target, mockProtocol.target],
            { initializer: "initialize", kind: "uups" }
        );

        const FUND_MANAGER_ROLE = await vault.FUND_MANAGER_ROLE();
        await vault.grantRole(FUND_MANAGER_ROLE, fundManager.address);
    });

    it ("Should allow deposits and issue shares", async function () {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);

        const tx = await vault.connect(Alice).deposit(depositAmount);
        expect(tx).to.emit(vault, "Deposited");

        const shares = await vault.balanceOf(Alice.address);
        expect(shares).to.equal(depositAmount);

        const totalAssets = await vault.availableTokens(depositToken.target);
        expect(totalAssets).to.equal(depositAmount);
    });

    it ("Should correctly calculate shares", async function() {
        const AliceDepositAmount = 1000;
        await depositToken.mint(Alice.address, AliceDepositAmount);
        await depositToken.connect(Alice).approve(vault.target, AliceDepositAmount);

        const tx = await vault.connect(Alice).deposit(AliceDepositAmount);
        expect(tx).to.emit(vault, "Deposited");

        const AliceShares = await vault.balanceOf(Alice.address);
        expect(AliceShares).to.equal(AliceDepositAmount);

        const availableTokens = await vault.availableTokens(depositToken.target);
        expect(availableTokens).to.equal(AliceDepositAmount);

        const BobDepositAmount = 500;
        await depositToken.mint(Bob.address, BobDepositAmount);
        await depositToken.connect(Bob).approve(vault.target, BobDepositAmount);

        await vault.connect(Bob).deposit(BobDepositAmount);

        const BobShares = await vault.balanceOf(Bob.address);
        expect(BobShares).to.equal(BobDepositAmount);

        const totalAssets = await vault.availableTokens(depositToken.target);
        expect(totalAssets).to.equal(AliceDepositAmount + BobDepositAmount);
    });

    it ("Should allow withdrawals and burn shares", async function () {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);

        await vault.connect(Alice).deposit(depositAmount);

        const shares = await vault.balanceOf(Alice.address);
        expect(shares).to.equal(depositAmount);

        const totalAssets = await vault.availableTokens(depositToken.target);
        expect(totalAssets).to.equal(depositAmount);

        const tx = await vault.connect(Alice).withdraw(shares);
        expect(tx).to.emit(vault, "Withdrawn");

        const remainingShares = await vault.balanceOf(Alice.address);
        expect(remainingShares).to.equal(0);

        const finalBalance = await depositToken.balanceOf(Alice.address);
        expect(finalBalance).to.equal(depositAmount);

        const totalSupply = await vault.availableTokens(depositToken.target);
        expect(totalSupply).to.equal(0);
    });

    it ("Should allow fund manager to execute swaps", async function() {
        const amountIn = 1000;
        const amountOutMinimum = 40;

        await tokenB.mint(owner.address, amountOutMinimum);
        await tokenB.approve(mockProtocol.target, amountOutMinimum);
        await mockProtocol.addTokens(tokenB.target, amountOutMinimum);
        const mockBalance = await tokenB.balanceOf(mockProtocol.target);
        expect(mockBalance).to.equal(amountOutMinimum);

        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);
        await vault.connect(Alice).deposit(depositAmount);

        const tx = await vault.connect(fundManager).swapTokens(
            depositToken.target,
            tokenB.target,
            amountIn,
            amountOutMinimum,
            0,
            ethers.parseUnits("0.01", 18), // 1%
            mockProtocol.target,
            mockProtocol.target
        );

        expect(await vault.availableTokens(depositToken.target)).to.equal(0);
        expect(await vault.availableTokens(tokenB.target)).to.equal(amountOutMinimum);
        expect(await depositToken.balanceOf(mockProtocol.target)).to.equal(amountIn);
        expect(tx).to.emit(vault, "TokenSwapped");
    });

    it ("Should not allow non fund manager to execute swaps", async function() {
        const amountIn = 1000;
        const amountOutMinimum = 40;

        await expect(vault.connect(BadActor).swapTokens(
            depositToken.target,
            tokenB.target,
            amountIn,
            amountOutMinimum,
            0,
            ethers.parseUnits("0.01", 18), // 1%
            mockProtocol.target,
            mockProtocol.target
        )).to.be.reverted;
    });

    it ("Should not allow fund manager to execute swaps if the vault doesn't have enough tokens", async function() {
        const amountIn = 1000;
        const amountOutMinimum = 40;

        await expect(vault.connect(fundManager).swapTokens(
            tokenA.target,
            tokenB.target,
            amountIn,
            amountOutMinimum,
            0,
            ethers.parseUnits("0.01", 18), // 1%
            mockProtocol.target,
            mockProtocol.target
        )).to.be.revertedWith("Vault: not enough tokenIn");
    });

    it ("Should allow fund manager to supply tokens to Aave", async function() {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);
        await vault.connect(Alice).deposit(depositAmount);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);

        const tx = await vault.connect(fundManager).supplyToAave(depositToken.target, depositAmount);
        expect(tx).to.emit(vault, "SuppliedToAave");
        expect(await vault.availableTokens(depositToken.target)).to.equal(0);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(depositAmount);
    });

    it ("Should not allow non fund manager to supply to Aave", async function() {
        const depositAmount = 1000;
        await expect(vault.connect(BadActor).supplyToAave(depositToken.target, depositAmount)).to.be.reverted;
    });

    it ("Should not allow to supply to Aave if the vault doesn't have enough tokens", async function() {
        const depositAmount = 1000;
        expect(await vault.availableTokens(depositToken.target)).to.equal(0);

        await expect(vault.connect(fundManager).supplyToAave(depositToken.target, depositAmount)).to.be.revertedWith("Insufficient funds");
    });

    it ("Should allow fund manager to borrow from Aave", async function() {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);
        await vault.connect(Alice).deposit(depositAmount);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        await vault.connect(fundManager).supplyToAave(depositToken.target, depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(depositAmount);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(0);

        await vault.connect(fundManager).enableCollateral(depositToken.target);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(depositAmount);

        const tx = await vault.connect(fundManager).borrowFromAave(depositToken.target, depositAmount, 2);
        expect(tx).to.emit(vault, "BorrowedFromAave");
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(0);
    });

    it ("Should not allow non fund manager to borrow from Aave", async function() {
        const depositAmount = 1000;

        await expect(vault.connect(BadActor).borrowFromAave(depositToken.target, depositAmount, 2)).to.be.reverted;
    });

    it ("should not allow to borrow from Aave if supply is not set as a collateral", async function() {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);
        await vault.connect(Alice).deposit(depositAmount);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        await vault.connect(fundManager).supplyToAave(depositToken.target, depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(depositAmount);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(0);

        await expect(vault.connect(fundManager).borrowFromAave(depositToken.target, depositAmount, 2)).to.be.revertedWith("mock: Insufficient collateral");
    });

    it ("Should not allow to borrow from Aave if the collateral is not enough", async function() {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);
        await vault.connect(Alice).deposit(depositAmount);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        await vault.connect(fundManager).supplyToAave(depositToken.target, depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(depositAmount);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(0);
        
        await vault.connect(fundManager).enableCollateral(depositToken.target);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(depositAmount);

        await expect(vault.connect(fundManager).borrowFromAave(depositToken.target, depositAmount + 10, 2)).to.be.revertedWith("mock: Insufficient collateral");
    });

    it ("Should allow fund manager to repay Aave laon", async function() {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);
        await vault.connect(Alice).deposit(depositAmount);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        await vault.connect(fundManager).supplyToAave(depositToken.target, depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(depositAmount);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(0);
        await vault.connect(fundManager).enableCollateral(depositToken.target);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(depositAmount);
        await vault.connect(fundManager).borrowFromAave(depositToken.target, depositAmount, 2);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(0);

        const tx = await vault.connect(fundManager).repayAaveLoan(depositToken.target, depositAmount);
        expect(tx).to.emit(vault, "RepaidAaveLoan");

        expect(await vault.availableTokens(depositToken.target)).to.equal(0);
        expect(await mockProtocol.totalDebt(depositToken.target)).to.equal(0);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(depositAmount);
    });

    it ("Should not allow non fund manager to repay Aave loan", async function() {
        const depositAmount = 1000;

        await expect(vault.connect(BadActor).repayAaveLoan(depositToken.target, depositAmount)).to.be.reverted;
    });

    it ("Should not allow to repay Aavel laon if the vault doesn't have enough tokens", async function() {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);
        await vault.connect(Alice).deposit(depositAmount);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        await vault.connect(fundManager).supplyToAave(depositToken.target, depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(depositAmount);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(0);
        await vault.connect(fundManager).enableCollateral(depositToken.target);
        expect(await mockProtocol.collateral(depositToken.target)).to.equal(depositAmount);
        await vault.connect(fundManager).borrowFromAave(depositToken.target, depositAmount, 2);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(0);

        await expect(vault.connect(fundManager).repayAaveLoan(depositToken.target, depositAmount + 10)).to.be.revertedWith("Insufficient funds");
    });

    it ("Should allow fund manager to withdraw Aave supply", async function() {
        const depositAmount = 1000;
        await depositToken.mint(Alice.address, depositAmount);
        await depositToken.connect(Alice).approve(vault.target, depositAmount);
        await vault.connect(Alice).deposit(depositAmount);
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
        await vault.connect(fundManager).supplyToAave(depositToken.target, depositAmount);
        expect(await mockProtocol.tokenBalances(depositToken.target)).to.equal(depositAmount);
        expect(await vault.availableTokens(depositToken.target)).to.equal(0);

        const tx = await vault.connect(fundManager).withdrawAaveSupply(depositToken.target, depositAmount);
        expect(tx).to.emit(vault, "WithdrawnFromAave");
        expect(await vault.availableTokens(depositToken.target)).to.equal(depositAmount);
    });

    it ("Should not allow non fund manager to withdraw Aave supply", async function() {
        const depositAmount = 1000;

        await expect(vault.connect(BadActor).withdrawAaveSupply(depositToken.target, depositAmount)).to.be.reverted;
    });
});
