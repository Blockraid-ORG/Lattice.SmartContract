// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenLocker {
    string public lockerName;

    IERC20 public token;
    address public owner;
   	address public funder;
    uint256 public startTime;
    uint256 public lockDuration;
    uint256[] public schedule; // e.g. [5000, 5000] (sums to 10000)

    uint256 public totalLocked;
    bool public finalized; 

    struct Beneficiary {
        uint256 allocation; // percentage of totalLocked (in basis points, out of 10000)
        uint256 claimed;    // how much already claimed
    }

    mapping(address => Beneficiary) public beneficiaries;
    address[] public beneficiaryList;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier notFinalized() {
        require(!finalized, "Beneficiaries already finalized");
        _;
    }

    constructor(
        string memory _lockerName,
        address _token,
        uint256 _startTime,
        uint256 _lockDuration,
        uint256[] memory _schedule,
        address _owner
    ) {
        require(_schedule.length > 0, "Schedule required");
        require(_startTime >= block.timestamp, "Start time must be in the future");

        lockerName = _lockerName;
        token = IERC20(_token);
        owner = _owner;
        startTime = _startTime;
        lockDuration = _lockDuration;

        uint256 total = 0;
        for (uint256 i = 0; i < _schedule.length; i++) {
            total += _schedule[i];
        }
        require(total == 10000, "Schedule must sum to 10000");
        schedule = _schedule;
    }

	function lock(uint256 amount) external {
		require(totalLocked == 0, "Already locked");
		require(amount > 0, "Amount must be > 0");

		funder = msg.sender;
		totalLocked = amount;
		token.transferFrom(msg.sender, address(this), amount);
	}

    // Owner assigns beneficiaries with percentages
    function setBeneficiaries(
        address[] calldata addrs,
        uint256[] calldata allocations
    ) external onlyOwner notFinalized {
        require(addrs.length == allocations.length, "Mismatched inputs");

        // reset old
        for (uint256 i = 0; i < beneficiaryList.length; i++) {
            delete beneficiaries[beneficiaryList[i]];
        }
        delete beneficiaryList;

        uint256 totalAlloc = 0;
        for (uint256 i = 0; i < addrs.length; i++) {
            require(addrs[i] != address(0), "Zero address");
            require(allocations[i] > 0, "Zero allocation");
            beneficiaries[addrs[i]] = Beneficiary({
                allocation: allocations[i],
                claimed: 0
            });
            beneficiaryList.push(addrs[i]);
            totalAlloc += allocations[i];
        }
        require(totalAlloc == 10000, "Allocations must sum to 10000");
    }

    // 🚨 Once called, beneficiaries cannot be modified again
    function finalize() external onlyOwner notFinalized {
        require(beneficiaryList.length > 0, "No beneficiaries set");
        finalized = true;
    }

    // Anyone can trigger a claim for a beneficiary
    function claim(address beneficiary) external {
        Beneficiary storage b = beneficiaries[beneficiary];
        require(b.allocation > 0, "Not beneficiary");

        uint256 claimable = getClaimableAmount(beneficiary);
        require(claimable > 0, "Nothing to claim");

        b.claimed += claimable;
        token.transfer(beneficiary, claimable);
    }

    // View: claimable for beneficiary
    function getClaimableAmount(address user) public view returns (uint256) {
        Beneficiary memory b = beneficiaries[user];
        if (b.allocation == 0) return 0;
        if (block.timestamp < startTime) return 0;

        uint256 elapsed = block.timestamp - startTime;
        uint256 unlocked;
        if (elapsed >= lockDuration) {
            unlocked = (totalLocked * b.allocation) / 10000;
        } else {
            uint256 portion = (elapsed * schedule.length) / lockDuration;
            uint256 unlockedPct = 0;
            for (uint256 i = 0; i < portion; i++) {
                unlockedPct += schedule[i];
            }
            uint256 unlockedTotal = (totalLocked * unlockedPct) / 10000;
            unlocked = (unlockedTotal * b.allocation) / 10000;
        }

        if (unlocked <= b.claimed) return 0;
        return unlocked - b.claimed;
    }

    // helper to view beneficiary list
    function getBeneficiaries() external view returns (address[] memory) {
        return beneficiaryList;
    }

    // Return complete beneficiary details
    function getCompleteBeneficiaries()
        external
        view
        returns (
            address[] memory addrs,
            uint256[] memory allocations,
            uint256[] memory totalAmounts,
            uint256[] memory claimed,
            uint256[] memory claimable
        )
    {
        uint256 len = beneficiaryList.length;
        addrs = new address[](len);
        allocations = new uint256[](len);
        totalAmounts = new uint256[](len);
        claimed = new uint256[](len);
        claimable = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address user = beneficiaryList[i];
            Beneficiary memory b = beneficiaries[user];
            addrs[i] = user;
            allocations[i] = b.allocation;
            totalAmounts[i] = (totalLocked * b.allocation) / 10000;
            claimed[i] = b.claimed;
            claimable[i] = getClaimableAmount(user);
        }
    }
}