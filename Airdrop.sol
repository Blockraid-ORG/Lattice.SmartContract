// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MultiScheduleAirdrop
 * @notice Owner can create multiple claim schedules. Each schedule is funded upfront with tokens.
 *         Each schedule has its own claim window and allocations. Users claim once per schedule.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Airdrop is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event ClaimWindowCreated(uint64 scheduleId, uint64 start, uint64 end, uint256 fundedAmount);
    event ClaimWindowCancelled(uint64 scheduleId);
    event AllocationSet(uint64 scheduleId, address indexed account, uint256 amount);
    event AllocationCleared(uint64 scheduleId, address indexed account);
    event Claimed(uint64 scheduleId, address indexed account, uint256 amount);
    event TokensWithdrawn(address indexed to, uint256 amount);
    event Sweep(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/
    IERC20 public immutable token;

    struct Schedule {
        uint64 start;
        uint64 end;
        uint256 fundedAmount;   // tokens funded for this schedule
        uint256 claimedAmount;  // tokens already claimed
        bool exists;
    }

    // scheduleId => Schedule
    mapping(uint64 => Schedule) public schedules;

    // scheduleId => user => allocation
    mapping(uint64 => mapping(address => uint256)) public allocation;

    // scheduleId => user => claimed?
    mapping(uint64 => mapping(address => bool)) public hasClaimed;

    // scheduleId => list of all users ever assigned an allocation
    mapping(uint64 => address[]) private _eligibleWallets;

    uint64 public nextScheduleId;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address initialOwner, IERC20 _token) Ownable(initialOwner) {
        require(address(_token) != address(0), "token=0");
        token = _token;
        nextScheduleId = 1;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new claim window and fund it with tokens from owner
    function createClaimWindow(uint64 _start, uint64 _end, uint256 fundAmount) external onlyOwner returns (uint64 id) {
        require(_start < _end, "bad window");
        require(fundAmount > 0, "fund=0");

        id = nextScheduleId++;
        schedules[id] = Schedule({
            start: _start,
            end: _end,
            fundedAmount: fundAmount,
            claimedAmount: 0,
            exists: true
        });

        token.safeTransferFrom(msg.sender, address(this), fundAmount);

        emit ClaimWindowCreated(id, _start, _end, fundAmount);
    }

    /// @notice Start immediately for a duration and fund
    function initiateNow(uint64 duration, uint256 fundAmount) external onlyOwner returns (uint64 id) {
        require(duration > 0, "duration=0");
        require(fundAmount > 0, "fund=0");

        uint64 start = uint64(block.timestamp);
        uint64 end = start + duration;

        id = nextScheduleId++;
        schedules[id] = Schedule({
            start: start,
            end: end,
            fundedAmount: fundAmount,
            claimedAmount: 0,
            exists: true
        });

        token.safeTransferFrom(msg.sender, address(this), fundAmount);

        emit ClaimWindowCreated(id, start, end, fundAmount);
    }

    function cancelClaimWindow(uint64 scheduleId) external onlyOwner {
        Schedule storage s = schedules[scheduleId];
        require(s.exists, "no schedule");

        uint256 refund = s.fundedAmount - s.claimedAmount;
        if (refund > 0) {
            token.safeTransfer(msg.sender, refund);
        }

        delete schedules[scheduleId];
        delete _eligibleWallets[scheduleId];
        emit ClaimWindowCancelled(scheduleId);
    }

    function setAllocation(uint64 scheduleId, address user, uint256 amount) external onlyOwner {
        require(schedules[scheduleId].exists, "no schedule");
        require(user != address(0), "user=0");

        if (allocation[scheduleId][user] == 0 && amount > 0) {
            _eligibleWallets[scheduleId].push(user);
        }

        allocation[scheduleId][user] = amount;
        emit AllocationSet(scheduleId, user, amount);
    }

    function setAllocations(uint64 scheduleId, address[] calldata users, uint256[] calldata amounts) external onlyOwner {
        require(schedules[scheduleId].exists, "no schedule");
        require(users.length == amounts.length, "length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            require(u != address(0), "user=0");
            if (allocation[scheduleId][u] == 0 && amounts[i] > 0) {
                _eligibleWallets[scheduleId].push(u);
            }
            allocation[scheduleId][u] = amounts[i];
            emit AllocationSet(scheduleId, u, amounts[i]);
        }
    }

    function clearAllocation(uint64 scheduleId, address user) external onlyOwner {
        require(schedules[scheduleId].exists, "no schedule");
        allocation[scheduleId][user] = 0;
        emit AllocationCleared(scheduleId, user);
    }

    function clearAllocations(uint64 scheduleId, address[] calldata users) external onlyOwner {
        require(schedules[scheduleId].exists, "no schedule");
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            if (u != address(0) && allocation[scheduleId][u] > 0) {
                allocation[scheduleId][u] = 0;
                emit AllocationCleared(scheduleId, u);
            }
        }
    }

    function withdrawUnclaimed(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to=0");
        token.safeTransfer(to, amount);
        emit TokensWithdrawn(to, amount);
    }

    function sweepToken(address erc20, address to, uint256 amount) external onlyOwner {
        require(erc20 != address(token), "use withdrawUnclaimed");
        require(to != address(0), "to=0");
        IERC20(erc20).safeTransfer(to, amount);
        emit Sweep(erc20, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIMING
    //////////////////////////////////////////////////////////////*/
    function claim(uint64 scheduleId) external nonReentrant {
        Schedule storage s = schedules[scheduleId];
        require(s.exists, "no schedule");
        require(block.timestamp >= s.start && block.timestamp <= s.end, "window inactive");
        require(!hasClaimed[scheduleId][msg.sender], "already claimed");

        uint256 amount = allocation[scheduleId][msg.sender];
        require(amount > 0, "no allocation");
        require(s.claimedAmount + amount <= s.fundedAmount, "exceeds funded");

        hasClaimed[scheduleId][msg.sender] = true;
        s.claimedAmount += amount;

        token.safeTransfer(msg.sender, amount);
        emit Claimed(scheduleId, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function claimWindowActive(uint64 scheduleId) external view returns (bool) {
        Schedule memory s = schedules[scheduleId];
        return (s.exists && block.timestamp >= s.start && block.timestamp <= s.end);
    }

    /// @notice Returns total number of wallets eligible to claim for a schedule
    function getTotalEligibleWallets(uint64 scheduleId) external view returns (uint256) {
        require(schedules[scheduleId].exists, "no schedule");
        return _eligibleWallets[scheduleId].length;
    }
}
