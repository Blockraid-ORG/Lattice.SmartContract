// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Whitelist {
    address public owner;
    mapping(address => bool) public isWhitelisted;

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function addToWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            isWhitelisted[users[i]] = true;
        }
    }

    function removeFromWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            isWhitelisted[users[i]] = false;
        }
    }

    function isUserWhitelisted(address user) external view returns (bool) {
        return isWhitelisted[user];
    }
}
