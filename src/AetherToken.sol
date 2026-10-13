// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title AETHER token
/// @notice Fixed-supply ERC-20. The whole 10,000 AETHER supply is minted once, in the constructor, to the
///         launcher that splits it into airdrop / liquidity / Reserve. There is no mint function, no owner,
///         and no pause: the supply can only go down (burn).
contract AetherToken {
    string public constant name = "AETHER";
    string public constant symbol = "AETHER";
    uint8 public constant decimals = 18;

    /// @notice Hard cap: 10,000 AETHER, all minted at launch.
    uint256 public constant MAX_SUPPLY = 10_000e18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(address recipient) {
        if (recipient == address(0)) revert ZeroAddress();
        totalSupply = MAX_SUPPLY;
        balanceOf[recipient] = MAX_SUPPLY;
        emit Transfer(address(0), recipient, MAX_SUPPLY);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    /// @notice Burn caller's tokens. Supply only decreases.
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    /// @notice Burn from an account using its allowance.
    function burnFrom(address from, uint256 value) external {
        _spendAllowance(from, msg.sender, value);
        _burn(from, value);
    }

    function _spendAllowance(address owner_, address spender, uint256 value) internal {
        uint256 current = allowance[owner_][spender];
        if (current != type(uint256).max) {
            if (current < value) revert InsufficientAllowance();
            unchecked {
                allowance[owner_][spender] = current - value;
            }
        }
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - value;
        }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _burn(address from, uint256 value) internal {
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - value;
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }
}
