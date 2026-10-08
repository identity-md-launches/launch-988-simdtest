// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ISIMDLaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @notice Fixed-supply SIMDTEST with a buy-only fee paid as token dividends.
/// @dev The external launch factory receives the entire mint and performs all launch allocations.
///      Only distributor discovery calls the factory (read-only, until cached). No privileged roles,
///      holder loops, or post-constructor mint paths exist.
contract SIMDTESTToken {
    string public constant name = "SIMDTEST";
    string public constant symbol = "SIMDTEST";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 * 1e18;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BUY_FEE_BPS = 300;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAGNITUDE = 1 << 128;

    address public immutable FACTORY;
    uint64 public immutable LAUNCH_NUMBER;
    address public dividendDistributor;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public eligibleSupply;
    uint256 public dividendsPerToken;
    uint256 public pendingDividends;
    uint256 public totalFeesCollected;
    uint256 public totalDividendsClaimed;

    mapping(address => uint256) private _checkpoint;
    mapping(address => uint256) private _scaledCredit;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event BuyFeeAccrued(uint256 amount);
    event DividendsDistributed(uint256 amount, uint256 eligibleBalance);
    event DividendClaimed(address indexed account, uint256 amount);
    event DividendDistributorResolved(address indexed distributor);

    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error NoDividends();
    error DistributorNotRegistered();

    constructor(uint64 launchNumber_) {
        FACTORY = msg.sender;
        LAUNCH_NUMBER = launchNumber_;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < amount) revert ERC20InsufficientAllowance(msg.sender, approved, amount);
            allowance[from][msg.sender] = approved - amount;
            emit Approval(from, msg.sender, approved - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function isExcludedFromDividends(address account) public view returns (bool) {
        return account == POOL_MANAGER || account == address(this) || account == BURN_ADDRESS || account == address(0)
            || account == FACTORY || account == dividendDistributor;
    }

    /// @notice Whole token minor units earned by an account and not yet claimed.
    /// @dev Earned credit stays with an account even after it transfers its entire balance away.
    function claimableDividends(address account) public view returns (uint256) {
        if (isExcludedFromDividends(account)) return 0;
        return (_scaledCredit[account] + balanceOf[account] * (dividendsPerToken - _checkpoint[account])) / MAGNITUDE;
    }

    /// @notice Claim only the caller's accrued dividends; there is no caller-selected recipient.
    function claim() external returns (uint256 amount) {
        _resolveDistributor();
        _accrue(msg.sender);
        amount = _scaledCredit[msg.sender] / MAGNITUDE;
        if (amount == 0) revert NoDividends();
        // Retain sub-wei credit across claims. The internal transfer makes no external call.
        _scaledCredit[msg.sender] %= MAGNITUDE;
        totalDividendsClaimed += amount;
        _move(address(this), msg.sender, amount);
        emit DividendClaimed(msg.sender, amount);
        // A former holder's claim can recreate eligible supply after everyone has sold.
        _distributePending();
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 available = balanceOf[from];
        if (available < amount) revert ERC20InsufficientBalance(from, available, amount);

        _resolveDistributor();
        // No dividends may accrue before the launch's distributor is known and excluded.
        if (from == POOL_MANAGER && dividendDistributor == address(0)) revert DistributorNotRegistered();

        // Incoming settlement always arrives whole, including a PoolManager self-transfer.
        uint256 fee = from == POOL_MANAGER && to != POOL_MANAGER ? amount * BUY_FEE_BPS / BPS : 0;
        if (fee != 0) {
            totalFeesCollected += fee;
            pendingDividends += fee;
            emit BuyFeeAccrued(fee);
            // Allocate using PRE-buy balances. Newly purchased tokens cannot earn this fee.
            _distributePending();
            _move(from, address(this), fee);
        }
        _move(from, to, amount - fee);
        // If there were no eligible holders, release queued fees once eligible tokens exist.
        _distributePending();
    }

    function _resolveDistributor() private {
        if (dividendDistributor != address(0)) return;
        address registered = ISIMDLaunchFactory(FACTORY).distributorOf(LAUNCH_NUMBER);
        if (registered == address(0)) return;
        // Registration follows deployment. Account for any balance received before registration;
        // no buy fees can have accrued yet. Cache once so later factory changes have no effect.
        if (!isExcludedFromDividends(registered)) eligibleSupply -= balanceOf[registered];
        dividendDistributor = registered;
        emit DividendDistributorResolved(registered);
    }

    function _move(address from, address to, uint256 amount) private {
        _accrue(from);
        if (to != from) _accrue(to);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (!isExcludedFromDividends(from)) eligibleSupply -= amount;
        if (!isExcludedFromDividends(to)) eligibleSupply += amount;
        emit Transfer(from, to, amount);
    }

    function _accrue(address account) private {
        if (isExcludedFromDividends(account)) return;
        uint256 delta = dividendsPerToken - _checkpoint[account];
        if (delta != 0) {
            // Multiply an index DIFFERENCE by the unchanged balance, not the lifetime index
            // by a new balance. This also handles a very small eligible supply safely.
            _scaledCredit[account] += balanceOf[account] * delta;
            _checkpoint[account] = dividendsPerToken;
        }
    }

    function _distributePending() private {
        uint256 amount = pendingDividends;
        uint256 supply = eligibleSupply;
        if (amount == 0 || supply == 0) return;
        pendingDividends = 0;
        dividendsPerToken += amount * MAGNITUDE / supply;
        emit DividendsDistributed(amount, supply);
    }
}
