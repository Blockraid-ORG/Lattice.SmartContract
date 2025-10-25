// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MultiAssetFaucet
 * @notice Faucet for ETH and multiple ERC20 tokens.
 * Each wallet has independent cooldowns for each asset (ERC or ETH).
 */

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "ERC20 transfer failed");
    }
}

contract MultiAssetFaucet {
    using SafeERC20 for IERC20;

    address public owner;
    bool public paused;

    struct TokenConfig {
        uint256 maxPerRequest; // scaled to token decimals
        uint256 cooldown;      // seconds
    }

    uint256 public ethMaxPerRequest;         // in wei
    uint256 public ethCooldown;              // seconds

    // ERC20 settings
    mapping(address => TokenConfig) public tokenConfigs;

    // Wallet cooldowns per asset
    // For ERC20: lastRequest[user][token]
    // For ETH:   lastRequest[user][address(0)]
    mapping(address => mapping(address => uint256)) public lastRequest;

    // ----------------------------
    // Events
    // ----------------------------
    event ERCRequested(address indexed user, address indexed token, uint256 amount);
    event ETHRequested(address indexed user, uint256 amount);
    event TokenConfigured(address indexed token, uint256 maxPerRequest, uint256 cooldown);
    event ETHConfigured(uint256 maxPerRequest, uint256 cooldown);
    event Withdrawn(address indexed token, uint256 amount, address to);
    event Paused(bool status);

    // ----------------------------
    // Modifiers
    // ----------------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    // ----------------------------
    // Constructor
    // ----------------------------
    constructor() {
        owner = msg.sender;
    }

    // ----------------------------
    // Admin Functions
    // ----------------------------
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    function configureToken(address token, uint256 maxPerRequest, uint256 cooldown) external onlyOwner {
        tokenConfigs[token] = TokenConfig(maxPerRequest, cooldown);
        emit TokenConfigured(token, maxPerRequest, cooldown);
    }

    function configureETH(uint256 maxPerRequest, uint256 cooldown) external onlyOwner {
        ethMaxPerRequest = maxPerRequest;
        ethCooldown = cooldown;
        emit ETHConfigured(maxPerRequest, cooldown);
    }

    // ----------------------------
    // Internal Cooldown Check
    // ----------------------------
    function _enforceCooldown(address user, address asset, uint256 cooldown) internal {
        uint256 last = lastRequest[user][asset];
        require(block.timestamp >= last + cooldown, "Cooldown active");
        lastRequest[user][asset] = block.timestamp;
    }

    // ----------------------------
    // ERC20 Request
    // ----------------------------
    function requestERC(address token, uint256 amount) external notPaused {
        require(amount > 0, "Zero amount");

        TokenConfig memory cfg = tokenConfigs[token];
        require(cfg.maxPerRequest > 0, "Token not configured");
        require(cfg.cooldown > 0, "Cooldown not set");

        _enforceCooldown(msg.sender, token, cfg.cooldown);

        IERC20 erc = IERC20(token);
        uint8 decimals = erc.decimals();
        uint256 realAmount = amount * (10 ** decimals);

        require(realAmount <= cfg.maxPerRequest, "Exceeds limit");
        require(erc.balanceOf(address(this)) >= realAmount, "Insufficient faucet balance");

        erc.safeTransfer(msg.sender, realAmount);
        emit ERCRequested(msg.sender, token, realAmount);
    }

    // ----------------------------
    // ETH Request
    // ----------------------------
    function requestETH(uint256 amount) external notPaused {
        require(amount > 0, "Zero amount");
        require(ethMaxPerRequest > 0, "ETH not configured");
        require(ethCooldown > 0, "ETH cooldown not set");
        require(amount <= ethMaxPerRequest, "Exceeds limit");

        _enforceCooldown(msg.sender, address(0), ethCooldown);

        require(address(this).balance >= amount, "Insufficient ETH");
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "ETH transfer failed");

        emit ETHRequested(msg.sender, amount);
    }

    // ----------------------------
    // Withdrawals (Owner only)
    // ----------------------------
    function withdrawToken(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Zero address");
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, amount, to);
    }

    function withdrawETH(uint256 amount, address payable to) external onlyOwner {
        require(to != address(0), "Zero address");
        require(address(this).balance >= amount, "Insufficient ETH");
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "ETH withdraw failed");
        emit Withdrawn(address(0), amount, to);
    }

    // ----------------------------
    // View Helpers
    // ----------------------------
    function remainingCooldown(address user, address asset) external view returns (uint256) {
        uint256 last = lastRequest[user][asset];
        uint256 cooldown = asset == address(0) ? ethCooldown : tokenConfigs[asset].cooldown;
        if (block.timestamp >= last + cooldown) return 0;
        return (last + cooldown) - block.timestamp;
    }

    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // ----------------------------
    // Fallbacks
    // ----------------------------
    receive() external payable {}
    fallback() external payable {}
}
