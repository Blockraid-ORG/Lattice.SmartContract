// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ERC20Token is ERC20, Pausable, Ownable {
    uint8 private _customDecimals;

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint8 decimals_
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _customDecimals = decimals_;
        _mint(msg.sender, initialSupply * 10 ** decimals_);
    }

    function decimals() public view virtual override returns (uint8) {
        return _customDecimals;
    }

    // Pause and unpause restricted to owner
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Custom pause logic: owner bypasses pause restriction
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (paused()) {
            // Allow owner to still transfer during pause
            require(
                from == owner() || to == owner(),
                "ERC20Pausable: token transfer while paused"
            );
        }
        super._update(from, to, value);
    }
}
