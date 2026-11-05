// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test tokens provided by ANDX. Use them as they are. Do not modify them.
/// All tokens have 6 decimals and a public, unrestricted mint (test only).

/// @dev Minimal ERC-20 core shared by the mocks. Not meant for production.
abstract contract MockERC20Base {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _spendAllowance(address from, uint256 amount) internal {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
    }

    /// @dev Moves `amount` out of `from`. Returns what `to` actually receives.
    function _move(address from, address to, uint256 amount) internal virtual returns (uint256 received) {
        require(to != address(0), "to zero");
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return amount;
    }
}

/// @notice USDX: a standard ERC-20.
contract USDX is MockERC20Base {
    constructor() MockERC20Base("USD X", "USDX") {}

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _move(from, to, amount);
        return true;
    }
}

/// @notice FOTX: burns 1% (rounded down) of every transfer and transferFrom.
/// The recipient receives amount - floor(amount / 100).
contract FOTX is MockERC20Base {
    constructor() MockERC20Base("Fee On Transfer X", "FOTX") {}

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal override returns (uint256) {
        require(to != address(0), "to zero");
        require(balanceOf[from] >= amount, "balance");
        uint256 burn = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - burn;
        totalSupply -= burn;
        emit Transfer(from, to, amount - burn);
        if (burn > 0) emit Transfer(from, address(0), burn);
        return amount - burn;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _move(from, to, amount);
        return true;
    }
}

/// @notice NRT: like USDT. transfer, transferFrom and approve return NOTHING.
/// They revert on failure.
contract NRT is MockERC20Base {
    constructor() MockERC20Base("No Return Token", "NRT") {}

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        _spendAllowance(from, amount);
        _move(from, to, amount);
    }
}

interface ITokenReceiverHook {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @notice HOOK: ERC-777 style callback token. A recipient can opt in with registerHook(true).
/// After every transfer to an opted-in recipient, the token calls
/// onTokenReceived(from, amount) on it. A revert in the hook reverts the transfer.
/// Used for reentrancy tests. Never allowlisted in the seed.
contract HOOK is MockERC20Base {
    mapping(address => bool) public hookRegistered;

    constructor() MockERC20Base("Hook Token", "HOOK") {}

    function registerHook(bool on) external {
        hookRegistered[msg.sender] = on;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal override returns (uint256) {
        uint256 r = super._move(from, to, amount);
        if (hookRegistered[to]) ITokenReceiverHook(to).onTokenReceived(from, amount);
        return r;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _move(from, to, amount);
        return true;
    }
}
