// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolState.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@aave/core-v3/contracts/interfaces/IPriceOracle.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract Vault is UUPSUpgradeable, ERC20Upgradeable, AccessControlUpgradeable {
    IERC20 public depositToken; // Token accepted for deposits
    ISwapRouter public uniswapRouter; // Uniswap Router
    IPool public aaveLendingPool; // Aave Lending Pool
    IPriceOracle public aaveOracle; // Aave oracle
   
    mapping (address => uint256) public availableTokens; // Tokens balances

    bytes32 constant public FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");
    bytes32 constant public UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    event Deposited(address user, uint256 amount);
    event Withdrawn(address user, uint256 amount);
    event TokenSwapped(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountIn,
        uint256 amountOut
    );
    event SuppliedToAave(address indexed asset, uint256 amount);
    event CollateralEnabled(address indexed asset);
    event BorrowedFromAave(address indexed asset, uint256 amount);
    event RepaidAaveLoan(address indexed asset, uint256 amount);
    event WithdrawnFromAave(address indexed asset, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address ) internal virtual override {
        require(hasRole(UPGRADER_ROLE, msg.sender), "Caller has no rights to upgrade");
    }

    function initialize(
        address _depositToken,
        address _uniswapRouter,
        address _aaveLendingPool,
        address _aaveOracle
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ERC20_init("Vault Share", "VSHARE");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(FUND_MANAGER_ROLE, msg.sender);

        depositToken = IERC20(_depositToken);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        aaveLendingPool = IPool(_aaveLendingPool);
        aaveOracle = IPriceOracle(_aaveOracle);
    }

    /**
     * @dev To deposit tokens and receive shares in return
     * @param _amount The amount of tokens to deposit
     */
    function deposit(uint256 _amount) external {
        address user = msg.sender;
        require(_amount > 0, "Deposit amount must be greater than zero");
        uint256 shares = totalSupply() == 0
            ? _amount
            : (_amount * totalSupply()) / availableTokens[address(depositToken)];
        
        availableTokens[address(depositToken)] += _amount;
        depositToken.transferFrom(user, address(this), _amount);
        _mint(user, shares);

        emit Deposited(user, _amount);
    }

    /**
     * @dev To withdraw tokens from vault by burning shares
     * @param _shares The amount of shares to burn
     */
    function withdraw(uint256 _shares) external {
        address user = msg.sender;
        require(_shares > 0, "Invalid share amount");
        uint256 amount = sharesToTokens(_shares);
        _burn(user, _shares);
        availableTokens[address(depositToken)] -= amount;
        depositToken.transfer(user, amount);

        emit Withdrawn(user, amount);
    }

    /**
     * @dev Converts a given number of Vault shares into the equivalent amount of the underlying deposit token.
     * @param _shares The number of Vault shares the user wants to convert to the underlying deposit token.
     */
    function sharesToTokens(uint256 _shares) public view returns (uint256 amount) {
        amount = (_shares * availableTokens[address(depositToken)]) / totalSupply();
    }

    /**
     * @dev To execute tokens swap
     * @param _tokenIn The address of the token being swapped (input token). 
     * @param _tokenOut The address of the token to be received in the swap (output token).
     * @param _amountIn The amount of _tokenIn to be swapped.
     * @param _amountOutMinimum The minimum amount of _tokenOut that must be received for the transaction to succeed.
     * @param _fee The Uniswap pool fee tier to use for the swap, specified in basis points.
     * @param _slippage The allowable deviation between the AMM (Automated Market Maker) price and the oracle price, expressed as a percentage (scaled by 1e18).
     * @param _priceFeedAddress The address of the Chainlink price feed for the pair being swapped.
     * @param _poolAddress The address of the Uniswap V3 pool used for the swap.
     */
    function swapTokens(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMinimum,
        uint24 _fee,
        uint256 _slippage,
        address _priceFeedAddress,
        address _poolAddress
    ) external onlyRole(FUND_MANAGER_ROLE) {
        require(availableTokens[_tokenIn] >= _amountIn, "Vault: not enough tokenIn");

        uint256 oraclePrice = getPriceFromOracle(_priceFeedAddress);
        uint256 poolPrice = getPoolPrice(_poolAddress);
        require(
            poolPrice >= oraclePrice * (1e18 - _slippage) / 1e18 &&
            poolPrice <= oraclePrice * (1e18 + _slippage) / 1e18,
            "AMM price deviates from oracle price"
        );

        IERC20(_tokenIn).approve(address(uniswapRouter), _amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: _fee,
                recipient: address(this),
                deadline: block.timestamp + 60,
                amountIn: _amountIn,
                amountOutMinimum: _amountOutMinimum,
                sqrtPriceLimitX96: 0
            });

        uint256 amountOut = uniswapRouter.exactInputSingle(params);

        availableTokens[_tokenIn] -= _amountIn;
        availableTokens[_tokenOut] += amountOut;

        emit TokenSwapped(_tokenIn, _tokenOut, _amountIn, amountOut);
    }

    /**
     * @dev To deposit a specified amount of an asset into the Aave protocol to earn yield or use it as collateral for borrowing.
     * @param _asset The address of the token to be supplied to the Aave protocol.
     * @param _amount The amount of the _asset to be deposited into Aave.
     */
    function supplyToAave(address _asset, uint256 _amount) external onlyRole(FUND_MANAGER_ROLE) {
        require(availableTokens[_asset] >= _amount, "Insufficient funds");

        IERC20(_asset).approve(address(aaveLendingPool), _amount);
        aaveLendingPool.supply(_asset, _amount, address(this), 0);
        availableTokens[_asset] -= _amount;

        emit SuppliedToAave(_asset, _amount);
    }

    /**
     * @dev To enable the specified asset to be used as a collateral in the Aave protocol.
     * @param _asset The address of the token to be enabled as a collateral.
     */
    function enableCollateral(address _asset) external onlyRole(FUND_MANAGER_ROLE) {
        aaveLendingPool.setUserUseReserveAsCollateral(_asset, true);
        emit CollateralEnabled(_asset);
    }

    /**
     * @dev To borrow a specified amount of an asset from Aave using the enabled collateral.
     * @param _asset The address of the token to borrow.
     * @param _amount The amount of _asset to borrow.
     * @param interestRateMode The interest rate model to use for the loan:
                                    1 for stable interest rate.
                                    2 for variable interest rate.
     */
    function borrowFromAave(
        address _asset,
        uint256 _amount,
        uint256 interestRateMode
    ) external onlyRole(FUND_MANAGER_ROLE) {
        (, , uint256 availableBorrowsETH, , , ) = aaveLendingPool.getUserAccountData(address(this));
        require(
            getAssetPriceInETH(_asset) * _amount <= availableBorrowsETH,
            "Insufficient borrowing power"
        );

        aaveLendingPool.borrow(_asset, _amount, interestRateMode, 0, address(this));
        availableTokens[_asset] += _amount;

        emit BorrowedFromAave(_asset, _amount);
    }

    /**
     * @dev To repay an outstanding loan in Aave for the specified asset.
     * @param _asset The address of the borrowed token being repaid.
     * @param _amount The amount of the borrowed _asset to repay.
     */
    function repayAaveLoan(address _asset, uint256 _amount) external onlyRole(FUND_MANAGER_ROLE) {
        if (_amount != type(uint256).max) {
            require(availableTokens[_asset] >= _amount, "Insufficient funds");
        }

        IERC20(_asset).approve(address(aaveLendingPool), _amount);
        uint256 amountRepaid = aaveLendingPool.repay(_asset, _amount, 2, address(this));
        availableTokens[_asset] -= amountRepaid;

        emit RepaidAaveLoan(_asset, amountRepaid);
    }

    /**
     * @dev To withdraw a specified amount of the Vault’s supplied _asset from Aave.
     * @param _asset The address of the token to withdraw from Aave.
     * @param _amount The amount of _asset to withdraw.
     */
    function withdrawAaveSupply(address _asset, uint256 _amount)
        external
        onlyRole(FUND_MANAGER_ROLE)
    {
        uint256 amountReceived = aaveLendingPool.withdraw(_asset, _amount, address(this));
        availableTokens[_asset] += amountReceived;

        emit WithdrawnFromAave(_asset, amountReceived);
    }

    function getAssetPriceInETH(address _asset) public view returns (uint256) {
        return aaveOracle.getAssetPrice(_asset);
    }

    function getPriceFromOracle(address _priceFeedAddress) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeedAddress);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price data");
        return uint256(price);
    }

    function getPoolPrice(address _poolAddress) public view returns (uint256 poolPrice) {
        IUniswapV3PoolState pool = IUniswapV3PoolState(_poolAddress);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        uint256 scaledSqrtPrice = sqrtPriceX96 / (2**96);
        poolPrice = scaledSqrtPrice * scaledSqrtPrice;
    }
}
