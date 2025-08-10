// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin contracts for ERC20 and Ownable.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal interface for Uniswap V2 Router and Factory, extended for token–token swaps and liquidity.
interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
         uint256 amountIn,
         uint256 amountOutMin,
         address[] calldata path,
         address to,
         uint256 deadline
    ) external;
    
    function swapExactTokensForTokens(
         uint256 amountIn,
         uint256 amountOutMin,
         address[] calldata path,
         address to,
         uint256 deadline
    ) external returns (uint[] memory amounts);

    function addLiquidityETH(
         address token,
         uint256 amountTokenDesired,
         uint256 amountTokenMin,
         uint256 amountETHMin,
         address to,
         uint256 deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    
    function addLiquidity(
         address tokenA,
         address tokenB,
         uint256 amountADesired,
         uint256 amountBDesired,
         uint256 amountAMin,
         uint256 amountBMin,
         address to,
         uint256 deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function factory() external pure returns (address);
    function WETH() external pure returns (address);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @title PUSPToken
/// @notice ERC-20 token with dynamic fees, anti-sniper measures, and an auto-liquidity mechanism that converts the liquidity fee portion to USDC.
contract PUSPToken is ERC20, Ownable {
    uint256 public constant TEAM_SHARE = 2;
    uint256 public constant MARKETING_SHARE = 1;
    uint256 public constant LIQUIDITY_SHARE = 1;
    uint256 public constant TOTAL_SHARES = TEAM_SHARE + MARKETING_SHARE + LIQUIDITY_SHARE; // 4

    mapping(address => bool) private _isFeeExempt;
    mapping(address => bool) private _isMaxWalletExempt;

    bool public tradingEnabled = false;
    uint256 public launchTime;

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    address public usdcAddress;

    bool private inSwap;
    uint256 public swapThreshold;

    address payable public teamWallet;
    address payable public marketingWallet;
    address payable public liquidityWallet;
    address public masterWallet;

    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(
         string memory name_,
         string memory symbol_,
         uint256 totalSupply_,
         address routerAddress,
         address _usdcAddress,
         address payable _teamWallet,
         address payable _marketingWallet,
         address payable _liquidityWallet,
         address _masterWallet
    ) ERC20(name_, symbol_) {
         _mint(_masterWallet, totalSupply_);

         uniswapV2Router = IUniswapV2Router02(routerAddress);
         uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
                        .createPair(address(this), uniswapV2Router.WETH());
         usdcAddress = _usdcAddress;

         teamWallet = _teamWallet;
         marketingWallet = _marketingWallet;
         liquidityWallet = _liquidityWallet;
         masterWallet = _masterWallet;

         _isFeeExempt[msg.sender] = true;
         _isFeeExempt[address(this)] = true;
         _isFeeExempt[uniswapV2Pair] = true;
         _isFeeExempt[masterWallet] = true;
         _isFeeExempt[teamWallet] = true;
         _isFeeExempt[marketingWallet] = true;
         _isFeeExempt[liquidityWallet] = true;

         _isMaxWalletExempt[msg.sender] = true;
         _isMaxWalletExempt[address(this)] = true;
         _isMaxWalletExempt[uniswapV2Pair] = true;
         _isMaxWalletExempt[masterWallet] = true;
         _isMaxWalletExempt[teamWallet] = true;
         _isMaxWalletExempt[marketingWallet] = true;
         _isMaxWalletExempt[liquidityWallet] = true;

         swapThreshold = totalSupply_ * 5 / 10000;
    }

    function enableTrading() external onlyOwner {
         require(!tradingEnabled, "Trading already enabled");
         tradingEnabled = true;
         launchTime = block.timestamp;
    }

    function setFeeExempt(address account, bool exempt) external onlyOwner {
         _isFeeExempt[account] = exempt;
    }

    function setMaxWalletExempt(address account, bool exempt) external onlyOwner {
         _isMaxWalletExempt[account] = exempt;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
         if (!tradingEnabled) {
              require(_isFeeExempt[from] || _isFeeExempt[to], "Trading not enabled");
         }

         if (tradingEnabled && block.timestamp < launchTime + 24 hours && !_isMaxWalletExempt[to]) {
              if (from == uniswapV2Pair) {
                   uint256 currentMaxWallet = _getCurrentMaxWallet();
                   require(balanceOf(to) + amount <= currentMaxWallet, "Exceeds max wallet limit");
              }
         }

         uint256 contractTokenBalance = balanceOf(address(this));
         if (!inSwap && to == uniswapV2Pair && contractTokenBalance >= swapThreshold) {
              swapAndLiquify(contractTokenBalance);
         }

         uint256 feeAmount = 0;
         if (!_isFeeExempt[from] && !_isFeeExempt[to]) {
              if (from == uniswapV2Pair || to == uniswapV2Pair) {
                   uint256 currentTax = _getCurrentTax();
                   feeAmount = (amount * currentTax) / 100;
              }
         }

         if (feeAmount > 0) {
              super._transfer(from, address(this), feeAmount);
         }
         super._transfer(from, to, amount - feeAmount);
    }

    function swapAndLiquify(uint256 tokenAmount) private lockTheSwap {
         uint256 liquidityPortion = (tokenAmount * LIQUIDITY_SHARE) / TOTAL_SHARES;
         uint256 otherPortion = tokenAmount - liquidityPortion;
         
         uint256 tokensForLiquidity = liquidityPortion / 2;
         uint256 tokensToSwap = liquidityPortion - tokensForLiquidity;

         uint256 usdcReceived = swapTokensForUSDC(tokensToSwap);
         if (usdcReceived > 0 && tokensForLiquidity > 0) {
              addLiquidityUSDC(tokensForLiquidity, usdcReceived);
         }

         uint256 teamAmount = (otherPortion * TEAM_SHARE) / (TEAM_SHARE + MARKETING_SHARE);
         uint256 marketingAmount = otherPortion - teamAmount;
         if (teamAmount > 0) {
              super._transfer(address(this), teamWallet, teamAmount);
         }
         if (marketingAmount > 0) {
              super._transfer(address(this), marketingWallet, marketingAmount);
         }
    }

    function swapTokensForUSDC(uint256 tokenAmount) private returns (uint256 usdcReceived) {
         address ;
         path[0] = address(this);
         path[1] = usdcAddress;
         
         _approve(address(this), address(uniswapV2Router), tokenAmount);
         
         uint[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
              tokenAmount,
              0,
              path,
              address(this),
              block.timestamp
         );
         usdcReceived = amounts[amounts.length - 1];
    }

    function addLiquidityUSDC(uint256 tokenAmount, uint256 usdcAmount) private {
         _approve(address(this), address(uniswapV2Router), tokenAmount);
         uniswapV2Router.addLiquidity(
              address(this),
              usdcAddress,
              tokenAmount,
              usdcAmount,
              0,
              0,
              liquidityWallet,
              block.timestamp
         );
    }

    function _getCurrentTax() internal view returns (uint256) {
         uint256 timeElapsed = block.timestamp - launchTime;
         if (timeElapsed < 1 minutes) return 45;
         else if (timeElapsed < 3 minutes) return 45;
         else if (timeElapsed < 10 minutes) return 25;
         else if (timeElapsed < 15 minutes) return 10;
         else if (timeElapsed < 24 hours) return 6;
         else return 4;
    }

    function _getCurrentMaxWallet() internal view returns (uint256) {
         uint256 total = totalSupply();
         uint256 timeElapsed = block.timestamp - launchTime;
         if (timeElapsed < 1 minutes) return total * 1 / 1000;
         else if (timeElapsed < 3 minutes) return total * 25 / 10000;
         else if (timeElapsed < 10 minutes) return total * 25 / 10000;
         else if (timeElapsed < 15 minutes) return total * 5 / 1000;
         else return total * 2 / 100;
    }

    receive() external payable {}
}
