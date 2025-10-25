// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ERC20Token.sol";
import "./TokenLocker.sol";
import "./Whitelist.sol";
import "./Airdrop.sol";

/// @notice Master factory using CREATE2 to deploy full ERC20 ecosystem
contract Create2Factory {
    address public owner;

    ERC20Token public token;
    Whitelist public whitelist;
    Airdrop public airdrop;
    address[] public lockers;

    event Deployed(address addr, bytes32 salt);
    event ERC20Deployed(address tokenAddress);
    event LockerDeployed(address lockerAddress, string name);
    event WhitelistDeployed(address whitelistAddress);
    event AirdropDeployed(address airdropAddress);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    /// @notice Generic CREATE2 deployer
    function deploy(bytes memory initCode, bytes32 salt)
        public
        returns (address addr)
    {
        assembly {
            addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(addr != address(0), "CREATE2 failed");
        emit Deployed(addr, salt);
    }

    /// @notice Deploy ERC20 + Lockers + Whitelist + Airdrop ecosystem via CREATE2
    function deployAll(
        bytes memory initCode,

        string[] memory _lockerNames,
        uint256[] memory _amounts,
        uint256[] memory _startTimes,
        uint256[] memory _durations,
        uint256[][] memory _schedules,

        bytes32 salt
    ) external onlyOwner {
        // === 1. Deploy ERC20Token using CREATE2 ===

        address tokenAddr = deploy(initCode, salt);
        token = ERC20Token(tokenAddr);
        emit ERC20Deployed(tokenAddr);

        token.transferOwnership(msg.sender);

        // === 2. Deploy TokenLockers ===
        uint256 totalAllocated = 0;
        for (uint256 i = 0; i < _lockerNames.length; i++) {
            TokenLocker locker = new TokenLocker(
                _lockerNames[i],
                address(token),
                _startTimes[i],
                _durations[i],
                _schedules[i],
                owner
            );

            lockers.push(address(locker));
            emit LockerDeployed(address(locker), _lockerNames[i]);

            token.approve(address(locker), _amounts[i]);
            locker.lock(_amounts[i]);
            totalAllocated += _amounts[i];
        }

        // === 3. Deploy Whitelist ===
        whitelist = new Whitelist(owner);
        emit WhitelistDeployed(address(whitelist));

        // === 4. Deploy Airdrop ===
        airdrop = new Airdrop(owner, IERC20(address(token)));
        emit AirdropDeployed(address(airdrop));

        // === 5. Transfer leftover tokens to owner ===
        uint256 remaining = token.balanceOf(address(this));
        if (remaining > 0) {
            token.transfer(owner, remaining);
        }
    }

    /// @notice Retrieve all deployed lockers
    function getLockers() external view returns (address[] memory) {
        return lockers;
    }
}
