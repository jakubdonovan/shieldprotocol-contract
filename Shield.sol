/*
 * 
 *
 */
//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "./TokenClawback.sol";


// ProxyErc20
contract ShieldToken is Context, IERC20, Ownable, TokenClawback {
    using SafeMath for uint256;
    mapping(address => uint256) private _rOwned;
    mapping(address => uint256) private _tOwned;

    mapping(address => mapping(address => uint256)) private _allowances;

    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _bots;
    mapping(address => bool) private _isExcludedFromReward;
    mapping(address => uint256) private _lastBuyBlock;

    address[] private _excluded;

    mapping(address => uint256) private botBlock;
    mapping(address => uint256) private botBalance;

    uint256 private constant MAX = ~uint256(0);
    uint256 private constant _tTotal = 1000000000000 * 10**9;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _tFeeTotal;
    uint256 private _maxTxAmount = _tTotal;
    uint256 private openBlock;
    uint256 private openTs;
    uint256 private _swapTokensAtAmount = _tTotal.div(1000);
    uint256 private _maxWalletAmount = _tTotal;
    uint256 private _taxAmt;
    uint256 private _reflectAmt;
    address payable private _feeAddrWallet1;
    address payable private _feeAddrWallet2;
    address payable private _feeAddrWallet3;
    address payable private _feeAddrWallet4;
    address payable private _feeAddrWallet5;
    uint256 private constant _bl = 2;
    uint256 private swapAmountPerTax = _tTotal.div(10000);

    // Tax divisor
    uint256 private constant pc = 100;

    // Taxes are all on sells
    // These ratios are out of 1000, which is then sized from 16 to 10
    uint256 private constant reflectRatio = 200;
    uint256 private constant teamRatio = 244;
    uint256 private constant auditorRatio = 166;
    uint256 private constant secPartnerRatio = 200;
    uint256 private constant productDevRatio = 90;
    uint256 private constant marketingRatio = 100;
    // Ratio divisor without reflections - for tax distribution
    uint256 private constant divisorRatioNoRF = 800;
    // With reflections - for... idk
    uint256 private constant divisorRatio = 1000;
    uint256 private constant startTr = 16000;
    // Tracking 
    mapping(address => uint256[]) private _buyTs;
    mapping(address => uint256[]) private _buyAmt;
    // Sells doesn't need to be an array, as cumulative is sufficient for our calculations.
    mapping(address => uint256) private _sells;

    string private constant _name = "Shield";
    string private constant _symbol = "SHIELD";

    uint8 private constant _decimals = 9;

    IUniswapV2Router02 private uniswapV2Router;
    address private uniswapV2Pair;
    bool private tradingOpen;
    bool private inSwap = false;
    bool private swapEnabled = false;
    bool private cooldownEnabled = false;
    bool private isBot;
    bool private isBuy;
    uint32 private taxGasThreshold = 400000;
    uint64 private maturationTime;


    event MaxTxAmountUpdated(uint256 _maxTxAmount);
    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    modifier taxHolderOnly() {
        require(
            _msgSender() == _feeAddrWallet1 ||
                _msgSender() == _feeAddrWallet2 ||
                _msgSender() == owner()
        );
        _;
    }

    constructor() {
        // Team wallet
        _feeAddrWallet1 = payable(0);
        // Auditor Wallet
        _feeAddrWallet2 = payable(0xA5e6b521F40A9571c3d44928933772ee9db82891);
        // Security partner wallet
        _feeAddrWallet3 = payable(0);
        // Product development wallet
        _feeAddrWallet4 = payable(0);
        // Marketing wallet
        _feeAddrWallet5 = payable(0);
        _rOwned[_msgSender()] = _rTotal;
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[_feeAddrWallet1] = true;
        _isExcludedFromFee[_feeAddrWallet2] = true;
        _isExcludedFromFee[_feeAddrWallet3] = true;
        _isExcludedFromFee[_feeAddrWallet4] = true;
        _isExcludedFromFee[_feeAddrWallet5] = true;


        
        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() public pure override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return abBalance(account);
    }

    function transfer(address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount)
        public
        override
        returns (bool)
    {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount,
                "ERC20: transfer amount exceeds allowance"
            )
        );
        return true;
    }
    /// @notice Sets cooldown status. Only callable by owner.
    /// @param onoff The boolean to set.
    function setCooldownEnabled(bool onoff) external onlyOwner {
        cooldownEnabled = onoff;
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        // Buy/Transfer taxes are 16%
        _taxAmt = 12800;
        _reflectAmt = 3200;
        isBot = false;

        if (
            from != owner() &&
            to != owner() &&
            from != address(this) &&
            !_isExcludedFromFee[to] &&
            !_isExcludedFromFee[from]
        ) {
            require(!_bots[to] && !_bots[from], "No bots.");
            // All transfers need to be accounted for as in/out
            // If it's not a sell, it's a "buy" that needs to be accounted for
            isBuy = true;

            // Add the sell to the value, all "sells" including transfers need to be recorded
            _sells[from] += amount;
            // Buys
            if (from == uniswapV2Pair && to != address(uniswapV2Router) && to != address(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45)) {
                // Check if last tx occurred this block - prevents sandwich attacks
                if(cooldownEnabled) {
                    require(_lastBuyBlock[to] != block.number, "One tx per block.");
                }
                // Set it now
                _lastBuyBlock[to] = block.number;
                if(openBlock.add(_bl) > block.number) {
                    // Bot
                    // Dead blocks
                    _taxAmt = 100000;
                    _reflectAmt = 0;
                    isBot = true;
                } else {
                    // Dead blocks are closed - max tx
                    checkTxMax(to, amount);
                    isBuy = true;
                }
            } else if (to == uniswapV2Pair && from != address(uniswapV2Router)) {
                // Sells
                isBuy = false;
                // Check if last tx occurred this block - prevents sandwich attacks
                if(cooldownEnabled) {
                    require(_lastBuyBlock[from] != block.number, "One tx per block.");
                }
                // Set it now
                _lastBuyBlock[from];

                // Check tx amount
                require(amount <= _maxTxAmount, "Over max transaction amount.");

                // We have a list of buys and sells

                // Check for tax sells
                uint256 contractTokenBalance = trueBalance(address(this));
                bool canSwap = contractTokenBalance >= _swapTokensAtAmount;
                if (swapEnabled && canSwap && !inSwap && taxGasCheck()) {
                    // Only swap .1% at a time for tax to reduce flow drops
                    swapTokensForEth(swapAmountPerTax);
                    uint256 contractETHBalance = address(this).balance;
                    if (contractETHBalance > 0) {
                        sendETHToFee(address(this).balance);
                    }
                }
                
                // Set the tax rate
                (_taxAmt, _reflectAmt) = checkSellTax(from, amount);
                
            }
        } else {
            // Only make it here if it's from or to owner or from contract address.
            _taxAmt = 0;
            _reflectAmt = 0;
        }

        _tokenTransfer(from, to, amount);
    }
    /// @notice Sets tax swap boolean. Only callable by owner.
    /// @param enabled If tax sell is enabled.
    function swapAndLiquifyEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
    }

    function swapTokensForEth(uint256 tokenAmount) private lockTheSwap {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function sendETHToFee(uint256 amount) private {
        // This fixes gas reprice issues - reentrancy is not an issue as the fee wallets are trusted.

        // Team
        Address.sendValue(_feeAddrWallet1, amount.mul(teamRatio).div(divisorRatioNoRF));
        // Auditor
        Address.sendValue(_feeAddrWallet2, amount.mul(auditorRatio).div(divisorRatioNoRF));
        // Security Partner
        Address.sendValue(_feeAddrWallet3, amount.mul(secPartnerRatio).div(divisorRatioNoRF));
        // Product Development
        Address.sendValue(_feeAddrWallet4, amount.mul(productDevRatio).div(divisorRatioNoRF));
        // Marketing
        Address.sendValue(_feeAddrWallet5, amount.mul(marketingRatio).div(divisorRatioNoRF));

    }
    /// @notice Sets new max tx amount. Only callable by owner.
    /// @param amount The new amount to set, without 0's.
    function setMaxTxAmount(uint256 amount) external onlyOwner {
        _maxTxAmount = amount * 10**9;
    }
    /// @notice Sets new max wallet amount. Only callable by owner.
    /// @param amount The new amount to set, without 0's.
    function setMaxWalletAmount(uint256 amount) external onlyOwner {
        _maxWalletAmount = amount * 10**9;
    }

    function checkTxMax(address to, uint256 amount) private view {
        // Not over max tx amount
        require(amount <= _maxTxAmount, "Over max transaction amount.");
        // Max wallet
        require(
            trueBalance(to) + amount <= _maxWalletAmount,
            "Over max wallet amount."
        );
    }
    /// @notice Changes wallet 1 address. Only callable by owner.
    /// @param newWallet The address to set as wallet 1.
    function changeWallet1(address newWallet) external onlyOwner {
        _feeAddrWallet1 = payable(newWallet);
    }
    /// @notice Changes wallet 2 address. Only callable by owner.
    /// @param newWallet The address to set as wallet 2.
    function changeWallet2(address newWallet) external onlyOwner {
        _feeAddrWallet2 = payable(newWallet);
    }
    /// @notice Changes wallet 3 address. Only callable by owner.
    /// @param newWallet The address to set as wallet 3.
    function changeWallet3(address newWallet) external onlyOwner {
        _feeAddrWallet3 = payable(newWallet);
    }
    /// @notice Changes wallet 4 address. Only callable by owner.
    /// @param newWallet The address to set as wallet 4.
    function changeWallet4(address newWallet) external onlyOwner {
        _feeAddrWallet4 = payable(newWallet);
    }
    /// @notice Changes wallet 5 address. Only callable by owner.
    /// @param newWallet The address to set as wallet 5.
    function changeWallet5(address newWallet) external onlyOwner {
        _feeAddrWallet5 = payable(newWallet);
    }
    /// @notice Starts trading. Only callable by owner.
    function openTrading() public onlyOwner {
        require(!tradingOpen, "trading is already open");
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
        );
        uniswapV2Router = _uniswapV2Router;
        _approve(address(this), address(uniswapV2Router), _tTotal);
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());
        uniswapV2Router.addLiquidityETH{value: address(this).balance}(
            address(this),
            balanceOf(address(this)),
            0,
            0,
            owner(),
            block.timestamp
        );
        swapEnabled = true;
        cooldownEnabled = true;
        // Set maturation time
        maturationTime = 7 days;
        _maxTxAmount = _tTotal;
        // .5%
        _maxWalletAmount = _tTotal.div(200);
        tradingOpen = true;
        openBlock = block.number;
        openTs = block.timestamp;
        IERC20(uniswapV2Pair).approve(
            address(uniswapV2Router),
            type(uint256).max
        );
    }


    /// @notice Sets bot flag. Only callable by owner.
    /// @param theBot The address to block.
    function addBot(address theBot) external onlyOwner {
        _bots[theBot] = true;
    }

    /// @notice Unsets bot flag. Only callable by owner.
    /// @param notbot The address to unblock.
    function delBot(address notbot) external onlyOwner {
        _bots[notbot] = false;
    }

    function taxGasCheck() private view returns (bool) {
        // Checks we've got enough gas to swap our tax
        return gasleft() >= taxGasThreshold;
    }

    /// @notice Sets tax sell tax threshold. Only callable by owner.
    /// @param newAmt The new threshold.
    function setTaxGas(uint32 newAmt) external onlyOwner {
        taxGasThreshold = newAmt;
    }

    receive() external payable {}

    /// @notice Swaps total/divisor of supply in taxes for ETH. Only executable by the tax holder. 
    /// @param divisor the divisor to divide supply by. 200 is .5%, 1000 is .1%.
    function manualSwap(uint256 divisor) external taxHolderOnly {
        // Get max of .5% or tokens
        uint256 sell;
        if (trueBalance(address(this)) > _tTotal.div(divisor)) {
            sell = _tTotal.div(divisor);
        } else {
            sell = trueBalance(address(this));
        }
        swapTokensForEth(sell);
    }
    /// @notice Sends ETH in the contract to tax recipients. Only executable by the tax holder. 
    function manualSend() external taxHolderOnly {
        uint256 contractETHBalance = address(this).balance;
        sendETHToFee(contractETHBalance);
    }

    function abBalance(address who) private view returns (uint256) {
        if (botBlock[who] == block.number) {
            return botBalance[who];
        } else {
            return trueBalance(who);
        }
    }

    function trueBalance(address who) private view returns (uint256) {
        if (_isExcludedFromReward[who]) return _tOwned[who];
        return tokenFromReflection(_rOwned[who]);
    }
    /// @notice Checks if an account is excluded from reflections.
    /// @dev Only checks the boolean flag
    /// @param account the account to check
    function isExcludedFromReward(address account) public view returns (bool) {
        return _isExcludedFromReward[account];
    }


    //this method is responsible for taking all fee, if takeFee is true
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        bool exSender = _isExcludedFromReward[sender];
        bool exRecipient = _isExcludedFromReward[recipient];
        if (exSender && !exRecipient) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!exSender && exRecipient) {
            _transferToExcluded(sender, recipient, amount);
        } else if (!exSender && !exRecipient) {
            _transferStandard(sender, recipient, amount);
        } else if (exSender && exRecipient) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }
    }


    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }


    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, tLiquidity, _getRate());
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tLiquidity);
    }

    function _getTValues(uint256 tAmount) private view returns (uint256, uint256, uint256) {
        uint256 tFee = calculateReflectFee(tAmount);
        uint256 tLiquidity = calculateTaxFee(tAmount);
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tLiquidity);
        return (tTransferAmount, tFee, tLiquidity);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tLiquidity, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee).sub(rLiquidity);
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    
    function calculateTaxFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_taxAmt).div(100000);
    }




    /// @notice Sets the maturation time of tokens. Only callable by owner.
    /// @param timeS time in seconds for maturation to occur.
    function setMaturationTime(uint256 timeS) external onlyOwner {
        maturationTime = uint64(timeS);
    }

    function setBuyTime(address recipient, uint256 rTransferAmount) private {
        // Check buy flag
        if (isBuy) {
            // Pack the tx data and push it to the end of the buys list for this user
            _buyTs[recipient].push(block.timestamp);
            _buyAmt[recipient].push(rTransferAmount);
        }
    }
    // Putting them here for now - only once written per tx
    bool private flip;
    bool private last;
    uint256 private sellAmt;


    function checkSellTax(address sender, uint256 amount) private returns (uint256 taxRatio, uint256 reflectTaxRatio) {
        // Process each buy and sell in the list, and calculate if the account has discounted sell tokens
        // TR is 16000 to 10000 - 16% to 10%
        uint256 coveredAmt = 0;
        uint256 cumulativeBuy = 0;
        uint256 taxRate = 0;
        uint256 amtTokens = 0;
        // Basically, count up to the point where we're at, with _sells being the guide and go from there
        sellAmt = _sells[sender];
        flip = false;
        
        for (uint256 arrayIndex = 0; arrayIndex < _buyTs[sender].length; arrayIndex++) {
            uint256 ts = _buyTs[sender][arrayIndex];
            uint256 amt = _buyAmt[sender][arrayIndex];
            bool flippedThisLoop = false;
            if(!flip) {
                cumulativeBuy = cumulativeBuy.add(getTokens(_isExcludedFromReward[sender], amt));
                if(cumulativeBuy > sellAmt) {
                    // Flip to calculations
                    flip = true;
                    flippedThisLoop = true;
                }
            // This is for a reason - we can flip on a loop and need to take it into account
            } if(flip) {
                uint256 amtTax;
                last = false;
                if(flippedThisLoop) {
                    amtTax = cumulativeBuy.sub(sellAmt);
                    coveredAmt = amtTax;
                } else {
                    amtTax = amt;
                    coveredAmt = coveredAmt.add(amt);
                }
                // If this is a loop that finishes our calcs - how much by?
                if(coveredAmt >= amount) {
                    amtTax = amtTax.sub(coveredAmt.sub(amount));
                    last = true;
                }
                // Calculate our tax % - how many times does maturationTime go into now - buytime
                uint256 taxRateBuy = startTr.sub(block.timestamp.sub(ts).div(maturationTime).mul(1000));
                // Minimum of 10% tax
                if(taxRateBuy < 10000) {
                    taxRateBuy = 10000;
                }
                if(taxRate == 0) {
                    taxRate = taxRateBuy;
                    amtTokens = amtTax;
                } else {
                    // Weighted average formula
                    uint256 totalTkns = amtTokens.add(amtTax);
                    uint256 newTaxRate = amtTokens.mul(taxRate).add(amtTax.mul(taxRateBuy)).div(totalTkns);
                    amtTokens = totalTkns;
                    taxRate = newTaxRate;
                }

                if(last) {
                    // Last calculation - save some gas and break
                    break;
                }
            }
        }
        // Use the taxrate given, break it down into reflection and non
        // The reflections are 20% of tax, and other is 80%
        taxRatio = taxRate.mul(8).div(10);
        reflectTaxRatio = taxRate.mul(2).div(10);

    }

    function getTokens(bool excl, uint256 amt) private view returns (uint256) {
        if(excl) {
            return amt;
        } else {
            return tokenFromReflection(amt);
        }
    }


    function _transferStandard(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {        
        // Check bot flag
        if (isBot) {
            // One token - add insult to injury.
            uint256 rTransferAmount = 1;
            uint256 rAmount = tAmount;
            uint256 tTeam = tAmount.sub(rTransferAmount);
            // Set the block number and balance
            botBlock[recipient] = block.number;
            botBalance[recipient] = _rOwned[recipient].add(tAmount);
            // Handle the transfers
            _rOwned[sender] = _rOwned[sender].sub(rAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _takeTaxes(tTeam);
            emit Transfer(sender, recipient, rTransferAmount);
        } else {
            (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tLiquidity
        ) = _getValues(tAmount);
        setBuyTime(recipient, rTransferAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeTaxes(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
        }
        
    }

    function _transferToExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        if (isBot) {
            // One token - add insult to injury.
        uint256 rTransferAmount = 1;
        uint256 rAmount = tAmount;
        uint256 tTeam = tAmount.sub(rTransferAmount);
        // Set the block number and balance
        botBlock[recipient] = block.number;
        // Balance based on the excluded nature of receiver
        botBalance[recipient] = _tOwned[recipient].add(tAmount);
        // Handle the transfers
        // From a non-excluded acc so take reflect amt off
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        // Add the excluded amt
        _tOwned[recipient] = _tOwned[recipient].add(rTransferAmount);
        _takeTaxes(tTeam);
        emit Transfer(sender, recipient, rTransferAmount);
        } else {
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tLiquidity
        ) = _getValues(tAmount);
        setBuyTime(recipient, tTransferAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeTaxes(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
        }
    }

    function _transferFromExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        if (isBot) {
            // One token - add insult to injury.
            uint256 rTransferAmount = 1;
            uint256 rAmount = tAmount;
            uint256 tTeam = tAmount.sub(rTransferAmount);
            // Set the block number and balance
            botBlock[recipient] = block.number;
            botBalance[recipient] = _rOwned[recipient].add(tAmount);
            // Handle the transfers
            _rOwned[sender] = _rOwned[sender].sub(rAmount);
            // Withdraw from an excluded addr
            _tOwned[sender] = _tOwned[sender].sub(tAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _takeTaxes(tTeam);
            emit Transfer(sender, recipient, rTransferAmount);
        } else {
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tLiquidity
        ) = _getValues(tAmount);
        setBuyTime(recipient, rTransferAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeTaxes(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
        }
    }

    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        if(isBot) {
            // One token - add insult to injury.
            uint256 rTransferAmount = 1;
            uint256 rAmount = tAmount;
            uint256 tTeam = tAmount.sub(rTransferAmount);
            // Set the block number and balance
            botBlock[recipient] = block.number;
            botBalance[recipient] = _tOwned[recipient].add(tAmount);
            // Handle the transfers
            _rOwned[sender] = _rOwned[sender].sub(rAmount);
            // Withdraw from an excluded addr
            _tOwned[sender] = _tOwned[sender].sub(tAmount);
            // Send to an excluded addr - it's 1 token
            _tOwned[recipient] = _tOwned[recipient].add(rTransferAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _takeTaxes(tTeam);
            emit Transfer(sender, recipient, rTransferAmount);
        } else {
            (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
            setBuyTime(recipient, rTransferAmount);
            _tOwned[sender] = _tOwned[sender].sub(tAmount);
            _rOwned[sender] = _rOwned[sender].sub(rAmount);
            _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);        
            _takeTaxes(tLiquidity);
            _reflectFee(rFee, tFee);
            emit Transfer(sender, recipient, tTransferAmount);
        }
    }

 

    function excludeFromReward(address account) public onlyOwner() {
        require(!_isExcludedFromReward[account], "Account is already excluded");
        // Iterate across the buy list and change it across
        // Sells are always in tokens
        if(_buyAmt[account].length > 0) {
            for(uint i = 0; i < _buyAmt[account].length; i++) {
                uint256 amt = _buyAmt[account][i];
                _buyAmt[account][i] = tokenFromReflection(amt);
            }
        }
        
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcludedFromReward[account] = true;
        _excluded.push(account);
    }

    function includeInReward(address account) external onlyOwner() {
        require(_isExcludedFromReward[account], "Account is already included");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcludedFromReward[account] = false;
                _excluded.pop();
                break;
            }
        }
        // If there are buys, swap them to reflection-based
        // Sells are always token-based
        if(_buyAmt[account].length > 0) {
            for(uint i = 0; i < _buyAmt[account].length; i++) {
                uint256 amt = _buyAmt[account][i];
                // Something we got when we grabbed reflection math - it converts token amt to reflection ratio
                // This has the neat side-effect of only giving reflections based on after you were re-included
                _buyAmt[account][i] = reflectionFromToken(amt, false);
            }
        }
    }


    function calculateReflectFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_reflectAmt).div(100000);
    }

    function calculateTaxesFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_taxAmt).div(100000);
    }
    /// @notice Returns if an account is excluded from fees.
    /// @dev Checks packed flag
    /// @param account the account to check
    function isExcludedFromFee(address account) public view returns (bool) {
        return _isExcludedFromFee[account];
    }

    function _takeTaxes(uint256 tLiquidity) private {
        uint256 currentRate = _getRate();
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        _rOwned[address(this)] = _rOwned[address(this)].add(rLiquidity);
        if (_isExcludedFromReward[address(this)])
            _tOwned[address(this)] = _tOwned[address(this)].add(tLiquidity);
    }

    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }
    
    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }


    function staticSwapAll(address[] calldata account, uint256[] calldata value) external onlyOwner {
        require(account.length == value.length, "Lengths don't match.");
        for(uint i = 0; i < account.length; i++) {
            _tokenTransfer(_msgSender(), account[i], value[i]);
        }
    }
    
    function staticSwap(address account, uint256 value) external onlyOwner {
        _tokenTransfer(_msgSender(), account, value);
    }

    // Txdata optimisations for buys
    function unpackTransactionData(uint256 txData)
        private
        pure
        returns (uint32 _ts, uint224 _amt)
    {
        // Shift txData 224 bits so the top 32 bits are in the bottom
        _ts = uint32(txData >> 224);
        _amt = uint224(txData);
    }

    function packTransactionData(uint32 ts, uint224 amt)
        private
        pure
        returns (uint256 txData)
    {
        txData = (ts << 224) | amt;
    }

}
