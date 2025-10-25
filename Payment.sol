// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MultiTokenPaymentProcessor
/// @notice Accepts multiple ERC20 tokens as payment, records transactions, owner can withdraw per token.
contract MultiTokenPaymentProcessor is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct TokenInfo {
        bool allowed;
        uint8 decimals;
    }

    struct Payment {
        address token;      // token used for this payment
        address payer;      // who paid
        uint256 amount;     // raw token units
        uint256 timestamp;  // block timestamp
        string memo;        // order id or description
    }

    uint256 public paymentCount;
    
    // token address => TokenInfo
    mapping(address => TokenInfo) public allowedTokens;

    // paymentId => Payment
    mapping(uint256 => Payment) private payments;

    // payer => list of paymentIds
    mapping(address => uint256[]) private paymentsByPayer;

    event PaymentReceived(uint256 indexed paymentId, address indexed token, address indexed payer, uint256 amount, string memo);
    event TokenAdded(address indexed token, uint8 decimals);
    event TokenRemoved(address indexed token);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event EmergencyTokenSweep(address indexed token, address indexed to, uint256 amount);

    constructor(address initialToken) Ownable(msg.sender) {
        if (initialToken != address(0)) {
            _addAllowedToken(initialToken);
        }
    }

    // ------------------------
    // Admin: Manage Token List
    // ------------------------

    function addAllowedToken(address token) external onlyOwner {
        _addAllowedToken(token);
    }

    function _addAllowedToken(address token) internal {
        require(token != address(0), "token address 0");
        require(!allowedTokens[token].allowed, "already allowed");

        uint8 decimals;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            decimals = 18;
        }

        allowedTokens[token] = TokenInfo({allowed: true, decimals: decimals});
        emit TokenAdded(token, decimals);
    }

    function removeAllowedToken(address token) external onlyOwner {
        require(allowedTokens[token].allowed, "not allowed");
        delete allowedTokens[token];
        emit TokenRemoved(token);
    }

    // ------------------------
    // Payment
    // ------------------------

    /// @notice Pay using an allowed ERC20 token.
    /// @param token The ERC20 token address used for payment.
    /// @param payer The payer (must equal msg.sender).
    /// @param amount Token amount in raw units.
    /// @param memo Any string to identify the payment (order id, etc.).
    function pay(address token, address payer, uint256 amount, string calldata memo) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(allowedTokens[token].allowed, "token not allowed");
        require(payer == msg.sender, "payer must be sender");
        require(amount > 0, "amount 0");

        IERC20(token).safeTransferFrom(payer, address(this), amount);

        uint256 pid = ++paymentCount;
        payments[pid] = Payment({
            token: token,
            payer: payer,
            amount: amount,
            timestamp: block.timestamp,
            memo: memo
        });
        paymentsByPayer[payer].push(pid);

        emit PaymentReceived(pid, token, payer, amount, memo);
    }

    // ------------------------
    // Withdrawals
    // ------------------------

    /// @notice Owner withdraw specific token amount.
    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(allowedTokens[token].allowed, "token not allowed");
        require(to != address(0), "to 0");
        require(amount > 0, "amount 0");

        uint256 bal = IERC20(token).balanceOf(address(this));
        require(amount <= bal, "insufficient balance");

        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Owner withdraw all balance of specific token.
    function withdrawAll(address token, address to) external onlyOwner nonReentrant {
        require(allowedTokens[token].allowed, "token not allowed");
        require(to != address(0), "to 0");

        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "no balance");

        IERC20(token).safeTransfer(to, bal);
        emit Withdrawn(token, to, bal);
    }

    /// @notice Emergency sweep for any token (even if not allowed).
    function emergencySweepToken(address token, address to) external onlyOwner nonReentrant {
        require(to != address(0), "to 0");
        require(token != address(0), "token 0");

        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "zero balance");

        IERC20(token).safeTransfer(to, bal);
        emit EmergencyTokenSweep(token, to, bal);
    }

    // ------------------------
    // Views
    // ------------------------

    function getPayment(uint256 paymentId) external view returns (Payment memory) {
        require(paymentId > 0 && paymentId <= paymentCount, "invalid id");
        return payments[paymentId];
    }

    function getPaymentsOf(address payer) external view returns (uint256[] memory) {
        return paymentsByPayer[payer];
    }

    // ------------------------
    // Pause Control
    // ------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
