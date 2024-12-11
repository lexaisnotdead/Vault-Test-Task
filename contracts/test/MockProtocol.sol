// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// MockProtocol contract is designed to simulate the behaviors of Uniswap, Aave, and Chainlink Oracles
contract MockProtocol {
    mapping(address => uint256) public tokenBalances; // Mock balances for supply/borrow & pool simulation
    mapping(address => uint256) public totalDebt; // Mock debt per asset
    mapping(address => uint256) public collateral; // Mock collateral per asset

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    // Token price from Oracle (Chainlink simulation)
    function latestRoundData() 
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        answer = 25; // random number
    }

    // Pool price for a token pair (e.g., Uniswap pool price)
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        sqrtPriceX96 = 396140812571321687967719751680; // 25
    }

    // Swap tokens (Uniswap simulation)
    function exactInputSingle(ExactInputSingleParams memory params) external returns (uint256 amountOut) {
        require(tokenBalances[params.tokenOut] >= params.amountOutMinimum, "mock: not enough tokenOut");

        tokenBalances[params.tokenIn] += params.amountIn;
        tokenBalances[params.tokenOut] -= params.amountOutMinimum;

        IERC20 tokenIn = IERC20(params.tokenIn);
        tokenIn.transferFrom(msg.sender, address(this), params.amountIn);

        IERC20 tokenOut = IERC20(params.tokenOut);
        tokenOut.transfer(msg.sender, params.amountOutMinimum);
        
        return params.amountOutMinimum;
    }

    // Supply to Aave (mock behavior)
    function supply(address asset, uint256 amount, address , uint16 ) external {
        tokenBalances[asset] += amount;
    }

    // Setting supply as a collateral (mock behavior)
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external {
        if (useAsCollateral) {
            collateral[asset] = tokenBalances[asset];
        }
    }

    // Borrow from Aave (mock behavior)
    function borrow(
        address asset,
        uint256 amount,
        uint256 ,
        uint16 ,
        address 
    ) external {
        require(collateral[asset] >= totalDebt[asset] + amount, "mock: Insufficient collateral");
        require(tokenBalances[asset] >= amount, "mock: Insufficient balance");

        totalDebt[asset] += amount;
        tokenBalances[asset] -= amount;
    }

    // Repay debt (mock behavior)
    function repay(
        address asset,
        uint256 amount,
        uint256 ,
        address 
    ) external returns (uint256 repaid) {
        repaid = amount > totalDebt[asset] ? totalDebt[asset] : amount;
        totalDebt[asset] -= repaid;
        tokenBalances[asset] += repaid;

        IERC20 token = IERC20(asset);
        token.transferFrom(msg.sender, address(this), repaid);
    }

    // Withdraw from Aave (mock behavior)
    function withdraw(address asset, uint256 amount, address ) external returns (uint256 withdrawn) {
        tokenBalances[asset] -= amount;
        withdrawn = amount;
    }

    // Get token price (mock Aave oracle)
    function getAssetPrice(address asset) external view returns (uint256) {
        return 4; // random number
    }

    // Aave-style account data
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        availableBorrowsBase = 61780005; // random number
    }

    function addTokens(address asset, uint256 amount) external {
        tokenBalances[asset] += amount;

        IERC20 token = IERC20(asset);
        token.transferFrom(msg.sender, address(this), amount);
    }
}
