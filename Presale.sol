// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IWhitelist {
    function isUserWhitelisted(address user) external view returns (bool);
}

contract Presale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    address public platform;
    uint256 public platformFeeBps; // basis points: 10000 = 100%

    // global defaults set at constructor (per your request)
    IERC20 public immutable saleToken;      // sale token for all presales
    IWhitelist public immutable whitelist;  // whitelist contract (can be address(0))
    uint256 public immutable globalWhitelistDuration;
    uint256 public immutable globalSweepDuration;

    struct PresaleEvent {
        // per-presale core data
        IERC20 token;                // will point to saleToken (set from constructor)
        IWhitelist whitelist;        // will point to whitelist (set from constructor)
        IERC20 stableToken;          // zero for ETH-mode
        uint256 hardCap;             // in wei or stable units (scaled)
        uint256 pricePerToken;       // price (same units as contributions)
        uint256 maxContribution;
        uint256 totalRaised;
        uint256 ethBalance;
        uint256 stableBalance;

        uint256 startTime;
        uint256 endTime;
        // whitelistDuration moved to constructor-global, but keep for readback
        uint256 whitelistDuration;
        uint256 claimDelay;
        uint256 claimTime;
        uint256 tokenDecimals;
        uint256 stableDecimals;
        uint256 sweepDuration;      // will be from constructor-global

        bool finalized;

        uint256 tokensNeeded;

        // vesting params (per-presale)
        uint16 initialReleaseBps;   // release at claimTime in bps (0..10000)
        uint256 cliffDuration;      // seconds after claimTime before vesting begins
        uint256 vestingDuration;    // seconds over which remaining tokens vest linearly

        // per-user accounting
        mapping(address => uint256) contributions;
        mapping(address => uint256) claimedAmount; // amount of sale tokens already claimed by user
        mapping(address => bool) refunded;
    }

    mapping(uint256 => PresaleEvent) private presales;
    uint256 public presaleCount;

    /* ---------- Events ---------- */
    event PresaleCreated(uint256 presaleId, address indexed token, address indexed stableToken, uint256 startTime, uint256 endTime, uint256 tokensDeposited);
    event Contributed(uint256 presaleId, address indexed user, uint256 amount, bool isStable);
    event Finalized(uint256 presaleId, uint256 timestamp, uint256 claimTime);
    event TokensClaimed(uint256 presaleId, address indexed user, uint256 amount);
    event FundsWithdrawn(uint256 presaleId, uint256 amount, address to, bool isStable);
    event Refunded(uint256 presaleId, address indexed user, uint256 amount, bool isStable);
    event Swept(uint256 presaleId, address indexed to, uint256 amount);

    /* ---------- Errors ---------- */
    error NotOwner();
    error InvalidSender();
    error PresaleNotStartedYet();
    error PresaleFinalized();
    error PresaleEnded();
    error HardCapReached();
    error NotWhitelisted();
    error ContributionTooHigh();
    error RefundFailed();
    error AlreadyFinalized();
    error PresaleStillActive();
    error ClaimNotStarted();
    error NoContribution();
    error WithdrawFailed();
    error RefundNotAllowed();
    error RefundTransferFailed();
    error ZeroAddress();
    error NoUnclaimedTokens();
    error AmountZero();
    error CannotRescueSaleToken();
    error InvalidParams();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Constructor sets global sale token, whitelist, whitelistDuration and sweepDuration
    /// All presales created later will use these values (per your request).
    constructor(
        address _owner,
        address _platform,
        uint256 _platformFeeBps,
        address _saleToken,        // sale token address (used for all presales)
        address _whitelist,        // whitelist contract (can be address(0))
        uint256 _whitelistDuration,
        uint256 _sweepDuration
    ) {
        if (_owner == address(0) || _platform == address(0) || _saleToken == address(0)) revert ZeroAddress();
        if (_platformFeeBps > 10000) revert InvalidParams();

        owner = _owner;
        platform = _platform;
        platformFeeBps = _platformFeeBps;

        saleToken = IERC20(_saleToken);
        whitelist = IWhitelist(_whitelist);
        globalWhitelistDuration = _whitelistDuration;
        globalSweepDuration = _sweepDuration;
    }

    /* ---------- Presale Management (ETH) ----------
       Note: activate functions no longer take token/whitelist/sweepDuration because those are global.
    */

    /// @notice Activate ETH-based presale. Monetary parameters are in wei (18 decimals).
    /// Caller (owner) must approve this contract for `tokensNeeded` on the sale token contract.
    /// Vesting params: initialReleaseBps (bps), cliffDuration (sec), vestingDuration (sec)
    function activatePresale(
        uint256 _hardCap,           // wei
        uint256 _pricePerToken,     // wei per 1 sale token
        uint256 _maxContribution,   // wei
        uint256 _startTime,
        uint256 _duration,
        uint256 _claimDelay,
        uint16 _initialReleaseBps,
        uint256 _cliffDuration,
        uint256 _vestingDuration
    ) external onlyOwner returns (uint256 presaleId) {
        if (_pricePerToken == 0) revert InvalidParams();
        if (_hardCap == 0) revert InvalidParams();
        if (_initialReleaseBps > 10000) revert InvalidParams();
        if (_cliffDuration > _duration) revert InvalidParams(); // optional check

        presaleId = ++presaleCount;
        PresaleEvent storage p = presales[presaleId];

        p.token = saleToken;
        p.stableToken = IERC20(address(0)); // ETH mode

        p.hardCap = _hardCap;
        p.pricePerToken = _pricePerToken;
        p.maxContribution = _maxContribution;

        p.startTime = _startTime;
        p.endTime = _startTime + _duration;
        p.whitelistDuration = globalWhitelistDuration;
        p.claimDelay = _claimDelay;

        // vesting params (order: vestingDuration then sweepDuration per your request) 
        p.initialReleaseBps = _initialReleaseBps;
        p.cliffDuration = _cliffDuration;
        p.vestingDuration = _vestingDuration;
        p.sweepDuration = globalSweepDuration;

        // token decimals
        try IERC20Metadata(address(p.token)).decimals() returns (uint8 td) {
            p.tokenDecimals = td;
        } catch {
            p.tokenDecimals = 18;
        }

        // stableDecimals for ETH mode = 18 (wei)
        p.stableDecimals = 18;

        // calculate tokens needed = (hardCap * 10**tokenDecimals) / pricePerToken
        uint256 tokensNeeded = (p.hardCap * (10 ** p.tokenDecimals)) / p.pricePerToken;
        if (tokensNeeded == 0) revert InvalidParams();
        p.tokensNeeded = tokensNeeded;

        // transfer sale tokens from msg.sender (owner) into contract
        p.token.safeTransferFrom(msg.sender, address(this), tokensNeeded);

        emit PresaleCreated(presaleId, address(p.token), address(0), p.startTime, p.endTime, tokensNeeded);
    }

    /* ---------- Presale Management (Stable) ---------- */

    /// @notice Activate stablecoin-based presale. Caller must approve sale tokens (tokensNeeded).
    function activatePresaleStable(
        address _stableToken,
        uint256 _hardCap,           // will be scaled by stable decimals
        uint256 _pricePerToken,     // stable units per 1 sale token (scaled to stable decimals)
        uint256 _maxContribution,
        uint256 _startTime,
        uint256 _duration,
        uint256 _claimDelay,
        uint16 _initialReleaseBps,
        uint256 _cliffDuration,
        uint256 _vestingDuration
    ) external onlyOwner returns (uint256 presaleId) {
        if (_stableToken == address(0)) revert ZeroAddress();
        if (_pricePerToken == 0) revert InvalidParams();
        if (_hardCap == 0) revert InvalidParams();
        if (_initialReleaseBps > 10000) revert InvalidParams();

        presaleId = ++presaleCount;
        PresaleEvent storage p = presales[presaleId];

        p.token = saleToken;
        p.stableToken = IERC20(_stableToken);

        // token decimals
        try IERC20Metadata(address(p.token)).decimals() returns (uint8 td) {
            p.tokenDecimals = td;
        } catch {
            p.tokenDecimals = 18;
        }

        // stable decimals
        uint8 sd;
        try IERC20Metadata(_stableToken).decimals() returns (uint8 sdd) {
            sd = sdd;
        } catch {
            sd = 18;
        }
        p.stableDecimals = sd;

        p.hardCap = _hardCap;
        p.pricePerToken = _pricePerToken;
        p.maxContribution = _maxContribution;

        p.startTime = _startTime;
        p.endTime = _startTime + _duration;
        p.whitelistDuration = globalWhitelistDuration;
        p.claimDelay = _claimDelay;

        // vesting params (initial / cliff / vesting)
        p.initialReleaseBps = _initialReleaseBps;
        p.cliffDuration = _cliffDuration;
        p.vestingDuration = _vestingDuration;
        p.sweepDuration = globalSweepDuration;

        // calculate tokens needed = (hardCap * 10**tokenDecimals) / pricePerToken
        uint256 tokensNeeded = (p.hardCap * (10 ** p.tokenDecimals)) / p.pricePerToken;
        if (tokensNeeded == 0) revert InvalidParams();
        p.tokensNeeded = tokensNeeded;

        // transfer sale tokens from msg.sender (owner) into contract
        p.token.safeTransferFrom(msg.sender, address(this), tokensNeeded);

        emit PresaleCreated(presaleId, address(p.token), address(p.stableToken), p.startTime, p.endTime, tokensNeeded);
    }

    /* ---------- Contributions (ETH) ---------- */

    function contribute(uint256 presaleId, address _user) external payable nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (address(p.stableToken) != address(0)) revert InvalidParams(); // not ETH presale
        if (_user != msg.sender) revert InvalidSender();
        if (block.timestamp < p.startTime) revert PresaleNotStartedYet();
        if (p.finalized) revert PresaleFinalized();
        if (block.timestamp > p.endTime) revert PresaleEnded();
        if (p.totalRaised >= p.hardCap) revert HardCapReached();

        if (block.timestamp < p.startTime + p.whitelistDuration && address(p.whitelist) != address(0)) {
            if (!p.whitelist.isUserWhitelisted(_user)) revert NotWhitelisted();
        }

        uint256 acceptedAmount = msg.value;
        if (p.totalRaised + acceptedAmount > p.hardCap) {
            acceptedAmount = p.hardCap - p.totalRaised;
        }
        if (acceptedAmount == 0) revert HardCapReached();
        if (p.contributions[_user] + acceptedAmount > p.maxContribution) revert ContributionTooHigh();

        // update state
        p.contributions[_user] += acceptedAmount;
        p.totalRaised += acceptedAmount;
        p.ethBalance += acceptedAmount;

        // refund excess msg.value if any
        uint256 refundAmount = msg.value - acceptedAmount;
        if (refundAmount > 0) {
            (bool sent, ) = _user.call{value: refundAmount}("");
            if (!sent) revert RefundFailed();
        }

        emit Contributed(presaleId, _user, acceptedAmount, false);

        // auto finalize if hardcap reached
        if (p.totalRaised >= p.hardCap && !p.finalized) {
            _finalizeInternal(presaleId);
        }
    }

    /* ---------- Contributions (Stable) ---------- */

    function contributeStable(uint256 presaleId, address _user, uint256 amount) external nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (address(p.stableToken) == address(0)) revert InvalidParams(); // not stable presale
        if (_user != msg.sender) revert InvalidSender();
        if (amount == 0) revert AmountZero();
        if (block.timestamp < p.startTime) revert PresaleNotStartedYet();
        if (p.finalized) revert PresaleFinalized();
        if (block.timestamp > p.endTime) revert PresaleEnded();
        if (p.totalRaised >= p.hardCap) revert HardCapReached();

        if (block.timestamp < p.startTime + p.whitelistDuration && address(p.whitelist) != address(0)) {
            if (!p.whitelist.isUserWhitelisted(_user)) revert NotWhitelisted();
        }

        uint256 acceptedAmount = amount;
        if (p.totalRaised + acceptedAmount > p.hardCap) {
            acceptedAmount = p.hardCap - p.totalRaised;
        }
        if (acceptedAmount == 0) revert HardCapReached();
        if (p.contributions[_user] + acceptedAmount > p.maxContribution) revert ContributionTooHigh();

        // Transfer only the accepted amount. User must pass amount >= acceptedAmount and approve accordingly.
        p.stableToken.safeTransferFrom(_user, address(this), acceptedAmount);

        p.contributions[_user] += acceptedAmount;
        p.totalRaised += acceptedAmount;
        p.stableBalance += acceptedAmount;

        emit Contributed(presaleId, _user, acceptedAmount, true);

        // auto finalize if hardcap reached
        if (p.totalRaised >= p.hardCap && !p.finalized) {
            _finalizeInternal(presaleId);
        }
    }

    /* ---------- Finalization ---------- */

    function finalize(uint256 presaleId) external nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (p.finalized) revert AlreadyFinalized();

        // allow finalize when hardcap reached OR after endTime
        if (block.timestamp <= p.endTime && p.totalRaised < p.hardCap) revert PresaleStillActive();
        _finalizeInternal(presaleId);
    }

    function _distributeFunds(
        uint256 presaleId,
        uint256 ethAmt,
        uint256 stAmt,
        IERC20 stableToken
    ) internal {
        // ETH
        if (ethAmt > 0) {
            uint256 feeAmt = (ethAmt * platformFeeBps) / 10000;
            uint256 ownerAmt = ethAmt - feeAmt;

            if (feeAmt > 0) {
                (bool feeSent, ) = platform.call{value: feeAmt}("");
                if (!feeSent) revert WithdrawFailed();
                emit FundsWithdrawn(presaleId, feeAmt, platform, false);
            }

            if (ownerAmt > 0) {
                (bool ownerSent, ) = owner.call{value: ownerAmt}("");
                if (!ownerSent) revert WithdrawFailed();
                emit FundsWithdrawn(presaleId, ownerAmt, owner, false);
            }
        }

        // Stable token
        if (stAmt > 0 && address(stableToken) != address(0)) {
            uint256 feeAmt = (stAmt * platformFeeBps) / 10000;
            uint256 ownerAmt = stAmt - feeAmt;

            if (feeAmt > 0) {
                stableToken.safeTransfer(platform, feeAmt);
                emit FundsWithdrawn(presaleId, feeAmt, platform, true);
            }

            if (ownerAmt > 0) {
                stableToken.safeTransfer(owner, ownerAmt);
                emit FundsWithdrawn(presaleId, ownerAmt, owner, true);
            }
        }
    }

    function _finalizeInternal(uint256 presaleId) internal {
        PresaleEvent storage p = presales[presaleId];
        p.finalized = true;
        p.claimTime = block.timestamp + p.claimDelay;
        emit Finalized(presaleId, block.timestamp, p.claimTime);

        // Auto-distribute funds to owner & platform if hardCap was reached
        if (p.totalRaised >= p.hardCap) {
            uint256 ethAmt = p.ethBalance;
            uint256 stAmt = p.stableBalance;
            p.ethBalance = 0;
            p.stableBalance = 0;

            _distributeFunds(presaleId, ethAmt, stAmt, p.stableToken);
        }
    }

    /* ---------- Claims with Vesting ---------- */

    /// @notice Claim sale tokens after finalization and claimTime according to vesting schedule.
    function claim(uint256 presaleId, address _user) external nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (_user != msg.sender) revert InvalidSender();
        if (!p.finalized) revert PresaleFinalized();
        if (p.claimTime == 0 || block.timestamp < p.claimTime) revert ClaimNotStarted();

        uint256 contributed = p.contributions[_user];
        if (contributed == 0) revert NoContribution();

        uint256 totalAlloc = (contributed * (10 ** p.tokenDecimals)) / p.pricePerToken;
        uint256 alreadyClaimed = p.claimedAmount[_user];

        uint256 claimable = _computeClaimable(p, totalAlloc, alreadyClaimed);
        if (claimable == 0) revert NoUnclaimedTokens();

        // update claimed
        p.claimedAmount[_user] = alreadyClaimed + claimable;

        p.token.safeTransfer(_user, claimable);

        emit TokensClaimed(presaleId, _user, claimable);
    }

    /// @notice computes total currently-claimable sale tokens for user minus alreadyClaimed
    function _computeClaimable(
        PresaleEvent storage p,
        uint256 totalAlloc,
        uint256 alreadyClaimed
    ) internal view returns (uint256) {
        // initial release available at claimTime
        uint256 initial = (totalAlloc * p.initialReleaseBps) / 10000;

        // if now < claimTime: nothing (this function should not be called then)
        if (block.timestamp < p.claimTime) return 0;

        // compute vested portion (remaining after initial)
        uint256 remaining = totalAlloc > initial ? totalAlloc - initial : 0;
        uint256 vested = 0;

        uint256 vestingStart = p.claimTime + p.cliffDuration;
        if (block.timestamp < vestingStart) {
            // vesting not started yet
            vested = 0;
        } else if (block.timestamp >= vestingStart + p.vestingDuration) {
            // all vested
            vested = remaining;
        } else {
            // linear vesting proportional to elapsed time since vestingStart
            uint256 elapsed = block.timestamp - vestingStart;
            // avoid division by zero if vestingDuration == 0
            if (p.vestingDuration == 0) {
                vested = remaining;
            } else {
                vested = (remaining * elapsed) / p.vestingDuration;
            }
        }

        uint256 totalAvailable = initial + vested;

        if (totalAvailable <= alreadyClaimed) return 0;
        return totalAvailable - alreadyClaimed;
    }

    /* ---------- Withdrawals (Owner) ---------- */

    function withdrawFunds(uint256 presaleId) external onlyOwner nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (!p.finalized) revert PresaleFinalized();
        if (p.totalRaised < p.hardCap) revert PresaleStillActive();

        uint256 amount = p.ethBalance;
        if (amount == 0) revert AmountZero();

        p.ethBalance = 0;
        _distributeFunds(presaleId, amount, 0, p.stableToken);
    }

    function withdrawStableFunds(uint256 presaleId) external onlyOwner nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (!p.finalized) revert PresaleFinalized();
        if (p.totalRaised < p.hardCap) revert PresaleStillActive();

        uint256 amount = p.stableBalance;
        if (amount == 0) revert AmountZero();

        p.stableBalance = 0;
        _distributeFunds(presaleId, 0, amount, p.stableToken);
    }

    /* ---------- Refunds (if presale failed) ---------- */

    function withdrawContributionIfFailed(uint256 presaleId, address _user) external nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (address(p.stableToken) != address(0)) revert InvalidParams();
        if (_user != msg.sender) revert InvalidSender();
        if (block.timestamp <= p.endTime) revert PresaleStillActive();
        if (p.finalized || p.totalRaised >= p.hardCap) revert RefundNotAllowed();

        uint256 amount = p.contributions[_user];
        if (amount == 0) revert NoContribution();

        p.contributions[_user] = 0;
        p.ethBalance -= amount;
        p.refunded[_user] = true;

        (bool sent, ) = msg.sender.call{value: amount}("");
        if (!sent) revert RefundTransferFailed();

        emit Refunded(presaleId, msg.sender, amount, false);
    }

    function withdrawStableContributionIfFailed(uint256 presaleId, address _user) external nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (address(p.stableToken) == address(0)) revert InvalidParams();
        if (_user != msg.sender) revert InvalidSender();
        if (block.timestamp <= p.endTime) revert PresaleStillActive();
        if (p.finalized || p.totalRaised >= p.hardCap) revert RefundNotAllowed();

        uint256 amount = p.contributions[_user];
        if (amount == 0) revert NoContribution();

        p.contributions[_user] = 0;
        p.stableBalance -= amount;
        p.refunded[_user] = true;

        p.stableToken.safeTransfer(msg.sender, amount);
        emit Refunded(presaleId, msg.sender, amount, true);
    }

    /* ---------- Sweep Unclaimed Tokens ---------- */

    /// @notice Sweep unclaimed sale tokens after claim window + sweepDuration
    /// claim window = claimTime + cliffDuration + vestingDuration
    function sweepUnclaimedTokens(uint256 presaleId, address to) external onlyOwner nonReentrant {
        PresaleEvent storage p = presales[presaleId];
        if (!p.finalized) revert PresaleFinalized();
        if (p.claimTime == 0) revert ClaimNotStarted();

        uint256 claimWindowEnd = p.claimTime + p.cliffDuration + p.vestingDuration;
        if (block.timestamp < claimWindowEnd + p.sweepDuration) revert PresaleStillActive();
        if (to == address(0)) revert ZeroAddress();

        uint256 remaining = p.token.balanceOf(address(this));
        if (remaining == 0) revert NoUnclaimedTokens();

        p.token.safeTransfer(to, remaining);
        emit Swept(presaleId, to, remaining);
    }

    /* ---------- View Helpers ---------- */

    function getContribution(uint256 presaleId, address user) external view returns (uint256) {
        return presales[presaleId].contributions[user];
    }

    /// returns how many sale tokens user can claim right now (taking into account already claimed)
    function getClaimableTokens(uint256 presaleId, address user) public view returns (uint256) {
        PresaleEvent storage p = presales[presaleId];
        uint256 contributed = p.contributions[user];
        if (contributed == 0) return 0;

        uint256 totalAlloc = (contributed * (10 ** p.tokenDecimals)) / p.pricePerToken;
        uint256 alreadyClaimed = p.claimedAmount[user];

        if (!p.finalized) return 0;
        if (p.claimTime == 0 || block.timestamp < p.claimTime) return 0;

        return _computeClaimable(p, totalAlloc, alreadyClaimed);
    }

    function getClaimedTokens(uint256 presaleId, address user) external view returns (uint256) {
        return presales[presaleId].claimedAmount[user];
    }

    function hasUserBeenRefunded(uint256 presaleId, address user) external view returns (bool) {
        return presales[presaleId].refunded[user];
    }

    function getPresaleEthBalance(uint256 presaleId) external view returns (uint256) {
        return presales[presaleId].ethBalance;
    }

    function getPresaleStableBalance(uint256 presaleId) external view returns (uint256) {
        return presales[presaleId].stableBalance;
    }

    function getPresale(uint256 presaleId)
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 claimTime,
            uint256 claimDelay,
            bool finalized,
            uint256 hardCap,
            uint256 totalRaised,
            uint256 tokensNeeded,
            uint16 initialReleaseBps,
            uint256 cliffDuration,
            uint256 vestingDuration,
            uint256 sweepDuration
        )
    {
        PresaleEvent storage p = presales[presaleId];
        startTime = p.startTime;
        endTime = p.endTime;
        claimTime = p.claimTime;
        claimDelay = p.claimDelay;
        finalized = p.finalized;
        hardCap = p.hardCap;
        totalRaised = p.totalRaised;
        tokensNeeded = p.tokensNeeded;
        initialReleaseBps = p.initialReleaseBps;
        cliffDuration = p.cliffDuration;
        vestingDuration = p.vestingDuration;
        sweepDuration = p.sweepDuration;
    }

    /* ---------- Admin rescue ---------- */

    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC20(tokenAddr).safeTransfer(to, amount);
    }

    // receive fallback to accept ETH
    receive() external payable {}
}