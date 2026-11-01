// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./precompile/StakerUpgradeable.sol";
import "./FreezableUpgradeable.sol";
import "./TransferPausableUpgradeable.sol";
import "./CustomErrors.sol";
import "./Registry.sol";

/**
 * @title StakedMonadV4
 * @author Brandon Mino <https://github.com/bmino>
 * @notice Core liquid staking contract for MON, allowing users to deposit MON to receive sMON shares
 *         Manages the lifecycle of staking, un-staking, and rewards distribution
 *         Facilitates batch processing of deposits and withdrawals
 *         Dynamically adjusts bonding/unbonding node allocation based on Registry weights
 *
 *         Changes in v2:
 *           * Added Deposit, BatchSent, Compounded, and VirtualSharesSnapshot events
 *           * Modified function logic of deposit, submitBatch, compound, and _updateFees to include above events
 *
 *         Changes in v3:
 *           * Bonding skips per-node delegations below the precompile dust threshold (1 gwei) instead of reverting
 *           * Unbonding that would leave a node below the dust threshold unbonds less, leaving exactly the threshold
 *           * Added initializeFromV2() which re-syncs the tracked stake of the given nodes with the precompile
 *           * Bonding returns early instead of dividing by zero when no node is below its target
 *
 *         Changes in v4:
 *           * Added a transfer pause, separate from the protocol pause: pauseTransfers() (ROLE_PAUSE) halts
 *             transfer() and transferFrom(); unpauseTransfers() (ROLE_UNPAUSE) resumes them. Deposits, unlocks,
 *             cancellations, batches, redemptions and fee claims stay governed by the protocol pause only, and
 *             the protocol pause leaves holder-to-holder transfers running
 *           * pauseProtocolAndTransfers() (ROLE_PAUSE) sets both the protocol pause and the transfer pause in one call
 *           * Renamed pause()/unpause() to pauseProtocol()/unpauseProtocol(). paused(), the Paused/Unpaused
 *             events and the EnforcedPause error keep their OpenZeppelin names
 *           * Added protocolPaused(), which returns the same value as paused(), to match transfersPaused()
 *           * unpauseProtocol() requires ROLE_UNPAUSE instead of ROLE_PAUSE, so a fast, lower-trust pauser key
 *             cannot resume the contract mid-incident
 *           * ROLE_FREEZE can freeze an account: it can no longer send, receive, approve a new allowance,
 *             spend an allowance, request/cancel an unlock, or redeem
 *           * ROLE_UNFREEZE can unfreeze an account. It is separate from ROLE_FREEZE so a fast, lower-trust
 *             freezer key cannot release a frozen thief (and thereby block seizure)
 *           * ROLE_SEIZE can move a frozen account's sMON to a recovery address with seizeBalance()
 *           * ROLE_SEIZE can take over a frozen account's unlock request with seizeUnlockRequest():
 *             a request still in the open batch is cancelled and its shares go to the recovery address;
 *             a request already submitted (unbonding) is reassigned so the recovery address redeems it
 *           * Freezing, seizing and unfreezing work while paused and while transfers are paused
 */
contract StakedMonadV4 is CustomErrors, Registry, StakerUpgradeable, FreezableUpgradeable, TransferPausableUpgradeable, UUPSUpgradeable, ERC20Upgradeable, AccessControlUpgradeable, PausableUpgradeable {
    uint16 private constant BIPS = 100_00;
    uint40 private constant YEAR = 365 days;

    /**
     * @dev Mirrors the staking precompile's `limits::dust_threshold()` (1 gwei):
     *      - `delegate()` reverts with `DelegationTooSmall` when `msg.value < dust_threshold()`
     *      - `undelegate()` sweeps the remaining stake into the withdrawal when `remaining < dust_threshold()`
     *      - Sources:
     *        - Delegate: https://github.com/category-labs/monad/blob/f38ac2da7c548f395425afab8ba1e7919cdeaef0/category/execution/monad/staking/staking_contract.cpp#L1253
     *        - Undelegate: https://github.com/category-labs/monad/blob/f38ac2da7c548f395425afab8ba1e7919cdeaef0/category/execution/monad/staking/staking_contract.cpp#L1395
     */
    uint96 private constant DUST_THRESHOLD = 1 gwei;

    struct UnlockRequest {
        /// @dev Number of shares the user will receive if the request is cancelled
        uint96 shares;
        /// @dev Value of the underlying asset that will be received upon redemption
        uint96 spotValue;
        /// @dev When this batch is completed, redemption is available
        uint40 batchId;
        /// @dev Store the exitFee (expressed in basis points) used for processing
        uint16 exitFeeInBips;
    }

    struct ExitFee {
        /// @dev Exit fee expressed in basis points
        uint16 bips;
        /// @dev Shares held in escrow that can still be returned to users by cancelling their unlock request
        uint96 escrowShares;
        /// @dev Shares converted from escrow that can be claimed by ROLE_FEE_CLAIMER
        uint96 protocolShares;
    }

    struct ManagementFee {
        /// @dev Annualized management fee expressed in basis points
        uint16 bips;
        /// @dev Accumulator for shares that ROLE_FEE_CLAIMER can mint but has not yet
        uint96 virtualSharesSnapshot;
        /// @dev Block time the management fee was last updated
        uint40 lastUpdate;
    }

    struct Batch {
        uint96 assets;
        uint96 shares;
    }

    struct BatchSubmission {
        /// @dev Epoch when batch was submitted. 0 indicates submission has not happened
        uint64 submissionEpoch;
        /// @dev Epoch when related stake movements will be in the consensus view
        uint64 activationEpoch;
    }

    event UnlockRequested(address indexed staker, uint256 unlockId, uint256 shares, uint256 spotValue, uint256 toll);
    event UnlockCancelled(address indexed staker, uint256 unlockId);
    event UnlockRedeemed(address indexed staker, uint256 unlockId, uint256 amount);
    event Contribution(uint256 amount, address benefactor);
    event FeesWithdrawn(uint256 managementFeeShares, uint256 exitFeeShares);
    event ManagementFeeAdjusted(uint256 newFee);
    event ExitFeeAdjusted(uint256 newFee);
    event Deposit(address indexed staker, uint256 shares, uint256 value);
    event BatchSent(uint256 batchId, uint256 sharesBurnt, uint256 unstakeValue);
    event Compounded(uint256 indexed nodeId, uint256 amount);
    event VirtualSharesSnapshot(uint256 shares);
    event Seized(address indexed account, address indexed to, uint256 shares);
    event UnlockRequestSeized(
        address indexed account,
        uint256 unlockId,
        address indexed to,
        uint256 shares,
        uint256 spotValue,
        bool reassigned
    );

    error InvalidAccount();

    // Registry related roles
    bytes32 public constant ROLE_ADD_NODE = keccak256("ROLE_ADD_NODE");
    bytes32 public constant ROLE_UPDATE_WEIGHTS = keccak256("ROLE_UPDATE_WEIGHTS");
    bytes32 public constant ROLE_DISABLE_NODE = keccak256("ROLE_DISABLE_NODE");
    bytes32 public constant ROLE_REMOVE_NODE = keccak256("ROLE_REMOVE_NODE");

    // Fee related roles
    bytes32 public constant ROLE_FEE_SETTER = keccak256("ROLE_FEE_SETTER");
    bytes32 public constant ROLE_FEE_CLAIMER = keccak256("ROLE_FEE_CLAIMER");
    bytes32 public constant ROLE_FEE_EXEMPTION = keccak256("ROLE_FEE_EXEMPTION");

    // Upgrade related roles
    bytes32 public constant ROLE_UPGRADE = keccak256("ROLE_UPGRADE");

    // Pause related roles
    bytes32 public constant ROLE_PAUSE = keccak256("ROLE_PAUSE");
    bytes32 public constant ROLE_UNPAUSE = keccak256("ROLE_UNPAUSE");

    // Freeze and seize related roles
    bytes32 public constant ROLE_FREEZE = keccak256("ROLE_FREEZE");
    bytes32 public constant ROLE_UNFREEZE = keccak256("ROLE_UNFREEZE");
    bytes32 public constant ROLE_SEIZE = keccak256("ROLE_SEIZE");

    uint256 public constant MINIMUM_CONTRIBUTE_THRESHOLD = 5_000 ether;

    // Total MON under management: batched deposits, staked, but excluding MON being unbonded
    uint96 public totalPooled;

    /// @dev Tracks the current batch being populated. Initialized to 1
    uint40 public currentBatchId;

    ExitFee private exitFee;
    ManagementFee private managementFee;

    mapping(address => bool) public isExitFeeExempt;
    mapping(uint256 => BatchSubmission) public batchSubmissions;
    mapping(uint256 => Batch) public batchDepositRequests;
    mapping(uint256 => Batch) public batchWithdrawRequests;
    mapping(address => UnlockRequest[]) public userUnlockRequests;

    // Allow receiving funds via sweep()
    receive() external payable {}

    modifier expectInitializedVersion(uint64 version) {
        if (Initializable._getInitializedVersion() != version) revert("Expected a different version");
        _;
    }

    constructor() {
        Initializable._disableInitializers();
    }

    /**
     * @dev It is recommended to transfer a small amount of MON when initializing to mitigate a rare DOS when:
     *      1) All users make unlock requests
     *      2) Batch is submitted, withdraw delay completes, and all sweep() calls are performed
     *      3) Some dust is still pending undelegation
     *      4) All unlock requests are redeemed
     */
    function initialize(address admin) external payable expectInitializedVersion(0) reinitializer(4) {
        UUPSUpgradeable.__UUPSUpgradeable_init();
        StakerUpgradeable.__Staker_init();
        FreezableUpgradeable.__Freezable_init();
        TransferPausableUpgradeable.__TransferPausable_init();
        ERC20Upgradeable.__ERC20_init("Kintsu Staked Monad", "sMON");
        AccessControlUpgradeable.__AccessControl_init();
        PausableUpgradeable.__Pausable_init();

        AccessControlUpgradeable._grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, admin);

        // Registry roles (managed by DEFAULT_ADMIN_ROLE)
        AccessControlUpgradeable._grantRole(ROLE_ADD_NODE, admin);
        AccessControlUpgradeable._grantRole(ROLE_UPDATE_WEIGHTS, admin);
        AccessControlUpgradeable._grantRole(ROLE_DISABLE_NODE, admin);
        AccessControlUpgradeable._grantRole(ROLE_REMOVE_NODE, admin);

        // Fee roles (self-managed)
        AccessControlUpgradeable._grantRole(ROLE_FEE_SETTER, admin);
        AccessControlUpgradeable._setRoleAdmin(ROLE_FEE_SETTER, ROLE_FEE_SETTER);
        AccessControlUpgradeable._grantRole(ROLE_FEE_CLAIMER, admin);
        AccessControlUpgradeable._setRoleAdmin(ROLE_FEE_CLAIMER, ROLE_FEE_CLAIMER);
        AccessControlUpgradeable._grantRole(ROLE_FEE_EXEMPTION, admin);
        AccessControlUpgradeable._setRoleAdmin(ROLE_FEE_EXEMPTION, ROLE_FEE_EXEMPTION);

        // Upgrade roles (self-managed)
        AccessControlUpgradeable._grantRole(ROLE_UPGRADE, admin);
        AccessControlUpgradeable._setRoleAdmin(ROLE_UPGRADE, ROLE_UPGRADE);

        // Other roles managed by DEFAULT_ADMIN_ROLE
        AccessControlUpgradeable._grantRole(ROLE_PAUSE, admin);
        AccessControlUpgradeable._grantRole(ROLE_UNPAUSE, admin);
        AccessControlUpgradeable._grantRole(ROLE_FREEZE, admin);
        AccessControlUpgradeable._grantRole(ROLE_UNFREEZE, admin);
        AccessControlUpgradeable._grantRole(ROLE_SEIZE, admin);

        currentBatchId = 1;

        managementFee = ManagementFee({
            bips: 2_00, // initial fee of 2.00%
            virtualSharesSnapshot: 0,
            lastUpdate: uint40(block.timestamp)
        });
        exitFee.bips = 5; // initial fee of 0.05%
    }

    /**
     * @dev Grants ROLE_UNPAUSE, ROLE_FREEZE, ROLE_UNFREEZE and ROLE_SEIZE to the caller, who must already hold DEFAULT_ADMIN_ROLE.
     * @dev Ensures the protocol pause and the transfer pause are both active
     * @dev Meant to run atomically inside `upgradeToAndCall`, where the caller is the admin performing the upgrade.
     *      Restricting it to the admin means an upgrade made without the call cannot be front-run to grab the roles.
     */
    function initializeFromV3() external expectInitializedVersion(3) reinitializer(4) onlyRole(DEFAULT_ADMIN_ROLE) {
        AccessControlUpgradeable._grantRole(ROLE_UNPAUSE, msg.sender);
        AccessControlUpgradeable._grantRole(ROLE_FREEZE, msg.sender);
        AccessControlUpgradeable._grantRole(ROLE_UNFREEZE, msg.sender);
        AccessControlUpgradeable._grantRole(ROLE_SEIZE, msg.sender);

        if (!PausableUpgradeable.paused()) PausableUpgradeable._pause();
        if (!TransferPausableUpgradeable.transfersPaused()) TransferPausableUpgradeable._pauseTransfers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ROLE_UPGRADE) {}

    function _authorizeAddNode() internal view override onlyRole(ROLE_ADD_NODE) {}
    function _authorizeUpdateWeight() internal view override onlyRole(ROLE_UPDATE_WEIGHTS) {}
    function _authorizeDisableNode() internal view override onlyRole(ROLE_DISABLE_NODE) {}
    function _authorizeRemoveNode(uint64 nodeId) internal view override onlyRole(ROLE_REMOVE_NODE) {
        if (StakerUpgradeable.getWithdrawIdsSize(nodeId) > 0) revert PendingWithdrawals();
        if (StakerUpgradeable.isForceWithdrawPending(nodeId)) revert PendingWithdrawals();
    }

    /**
     * @dev A frozen account cannot send, receive, approve, spend allowances, request/cancel an unlock, or redeem
     * @dev Works while paused. This contract and the zero address can never be frozen, since every mint, burn,
     *      unlock and cancellation moves shares through them.
     */
    function _authorizeFreeze(address account) internal view override onlyRole(ROLE_FREEZE) {
        if (account == address(0) || account == address(this)) revert InvalidAccount();
    }
    /**
     * @dev Separate from ROLE_FREEZE: freezing only protects, but unfreezing a thief releases the funds and
     *      makes them unseizable, so it can be kept on a higher-trust key than the freezer
     */
    function _authorizeUnfreeze(address) internal view override onlyRole(ROLE_UNFREEZE) {}

    /// @dev Same role split as the protocol pause: a fast, lower-trust key may halt transfers but not resume them
    function _authorizePauseTransfers() internal view override onlyRole(ROLE_PAUSE) {}
    function _authorizeUnpauseTransfers() internal view override onlyRole(ROLE_UNPAUSE) {}

    /**
     * @notice Converts MON into LST shares at the current block timestamp
     * @dev `totalShares()` accounts for both minted and mintable shares
     */
    function convertToShares(uint96 assets) public view returns (uint96 shares) {
        uint256 _totalPooled = totalPooled; // shadow
        if (_totalPooled == 0) {
            // This happens upon initial stake
            // Also known as 1:1 redemption ratio
            shares = assets;
        } else {
            shares = uint96(uint256(assets) * uint256(totalShares()) / _totalPooled);
        }
    }

    /**
     * @notice Converts LST shares into MON at the current block timestamp
     * @notice Does not apply exit fee
     * @dev `totalShares()` accounts for both minted and mintable shares
     */
    function convertToAssets(uint96 shares) public view returns (uint96 assets) {
        uint256 _totalShares = totalShares();
        if (_totalShares == 0) {
            // This happens upon initial stake
            // Also known as 1:1 redemption ratio
            assets = shares;
        } else {
            assets = uint96(uint256(shares) * uint256(totalPooled) / _totalShares);
        }
    }

    /**
     * @notice Shares that could exist at the current block timestamp
     * @notice Includes both minted and mintable shares
     */
    function totalShares() public view returns (uint96) {
        return uint96(ERC20Upgradeable.totalSupply()) + getMintableProtocolShares();
    }

    function getAllUserUnlockRequests(address user) external view returns (UnlockRequest[] memory) {
        return userUnlockRequests[user];
    }

    function getExitFeeBips() external view returns (uint16) {
        return exitFee.bips;
    }

    function getManagementFeeBips() external view returns (uint16) {
        return managementFee.bips;
    }

    /// @notice Shares that could be minted by the protocol at the current block timestamp
    function getMintableProtocolShares() public view returns (uint96 shares) {
        ManagementFee memory _managementFee = managementFee; // shadow (SLOAD 1 slot)

        shares = _managementFee.virtualSharesSnapshot;

        uint256 time = block.timestamp - _managementFee.lastUpdate;
        if (time > 0) {
            uint256 feeShares = _calculateFee(ERC20Upgradeable.totalSupply() + shares, _managementFee.bips);
            uint256 feeSharesTimeWeighted = feeShares * time / YEAR;
            shares += uint96(feeSharesTimeWeighted);
        }
    }

    function calculateStakeDeltas(uint96 newTotalStaked) external view returns (
        uint96 totalExcess,
        uint96 totalDeficit,
        uint96[] memory nodeExcesses,
        uint96[] memory nodeDeficits
    ) {
        return _calculateStakeDeltas(Registry.nodes, newTotalStaked);
    }

    /// @notice Whether the protocol is paused. Same value as `paused()`; named to match `transfersPaused()`.
    function protocolPaused() external view returns (bool) {
        return PausableUpgradeable.paused();
    }

    /**
     * @notice Deposit asset into the protocol and receive shares to represent your position
     * @notice Deposit amount must be specified by `msg.value`
     * @param minShares - Minimum quantity of shares that must be minted to prevent front running
     * @param receiver - Recipient of the minted shares
     * @return shares - Quantity of shares minted
     */
    function deposit(uint96 minShares, address receiver) external payable whenNotPaused returns (uint96 shares) {
        if (msg.value > type(uint96).max) revert DepositOverflow();

        _updateFees();

        shares = convertToShares(uint96(msg.value));
        if (shares == 0) revert NoChange();
        if (shares < minShares) revert MinimumDeposit();

        ERC20Upgradeable._mint(receiver, shares);

        totalPooled += uint96(msg.value);

        batchDepositRequests[currentBatchId].assets += uint96(msg.value);

        emit Deposit(receiver, shares, msg.value);
    }

    /*
     * @notice Step 1 of 2 in process of withdrawing assets
     * @notice Transfers `shares` to the vault contract
     * @notice Unlock is batched into current batch request
     * @notice Applies exit fee if present
     */
    function requestUnlock(uint96 shares, uint96 minSpotValue) external whenNotPaused returns (uint96 spotValue) {
        _updateFees();

        // Calculate exit toll (if any)
        uint16 exitFeeInBips;
        uint96 sharesToFee;
        if (!isExitFeeExempt[msg.sender]) {
            exitFeeInBips = exitFee.bips;
            sharesToFee = _calculateFee(shares, exitFeeInBips);
        }

        uint96 sharesToUnlock = shares - sharesToFee;
        spotValue = convertToAssets(sharesToUnlock);
        if (spotValue == 0) revert NoChange();
        if (spotValue < minSpotValue) revert MinimumUnlock();

        uint40 _currentBatchId = currentBatchId; // shadow

        // Update user's unlock requests
        userUnlockRequests[msg.sender].push(UnlockRequest({
            shares: shares,
            spotValue: spotValue,
            batchId: _currentBatchId,
            exitFeeInBips: exitFeeInBips
        }));

        // Update current batch
        Batch memory _batchWithdrawRequest = batchWithdrawRequests[_currentBatchId]; // shadow (SLOAD 1 slot)
        _batchWithdrawRequest.assets += spotValue;
        _batchWithdrawRequest.shares += sharesToUnlock;
        batchWithdrawRequests[_currentBatchId] = _batchWithdrawRequest;

        // Add shares to escrow
        if (sharesToFee > 0) {
            exitFee.escrowShares += sharesToFee;
        }

        // Transfer and escrow all shares
        // Directly transfer avoiding need for approval
        ERC20Upgradeable._transfer(msg.sender, address(this), shares);

        emit UnlockRequested(
            msg.sender,
            userUnlockRequests[msg.sender].length - 1,
            sharesToUnlock,
            spotValue,
            sharesToFee
        );
    }

    /**
     * @notice Allow user to cancel their unlock request
     * @notice Most users will have 1 concurrent unlock request (`unlockIndex` == 0) but advanced users may have more
     * @notice Must be done before the associated batch is submitted
     * @dev Order of unlock requests is not guaranteed between cancellations
     */
    function cancelUnlockRequest(uint256 unlockIndex) external whenNotPaused {
        uint96 shares = _removeOpenUnlockRequest(msg.sender, unlockIndex);

        // Return shares to caller (reverts if the caller is frozen)
        ERC20Upgradeable._transfer(address(this), msg.sender, shares);

        emit UnlockCancelled(msg.sender, unlockIndex);
    }

    /**
     * @notice Step 2 of 2 in process of withdrawing assets
     * @notice Associated batch must have been submitted and the cooldown period elapsed
     * @dev Might need to first call `sweep()` to make funds available
     * @dev Deletes the caller's unlock request
     */
    function redeem(uint256 unlockIndex, address payable receiver) external whenNotPaused returns (uint96 assets) {
        // Redemption pays out MON without moving sMON, so the transfer-level freeze check does not apply here
        _requireNotFrozen(msg.sender);
        _requireNotFrozen(receiver);

        UnlockRequest[] storage userUnlockRequestArray = userUnlockRequests[msg.sender];
        UnlockRequest memory userUnlockRequest = userUnlockRequestArray[unlockIndex]; // shadow (SLOAD 1 slot)
        BatchSubmission memory batchSubmission = batchSubmissions[userUnlockRequest.batchId]; // shadow (SLOAD 1 slot)
        if (batchSubmission.submissionEpoch == 0) revert BatchNotSubmitted();

        (uint64 currentEpoch,) = StakerUpgradeable.getEpoch();
        if (currentEpoch < batchSubmission.activationEpoch + StakerUpgradeable.getWithdrawDelay()) revert WithdrawDelay();

        // Delete completed user unlock request
        _deleteUnlockRequest(userUnlockRequestArray, unlockIndex);

        // Send redeemed MON to user
        assets = userUnlockRequest.spotValue;
        (bool success,) = receiver.call{value: assets}("");
        if (!success) revert TransferFailed();

        emit UnlockRedeemed(msg.sender, unlockIndex, assets);
    }

    /**
     * @notice Processes deposit and withdrawal requests and allocates MON according to Registry weights
     * @dev Might need to first call `sweep()`
     * @dev For a net ingress batch, the amount bonded may be less than the requested amount due to integer arithmetic,
     *      or because a node's allocation is below the precompile dust threshold and is skipped.
     *      The remaining amount, or 'dust' is scheduled to be bonded in the next batch.
     * @dev For a net egress batch, the amount unbonded may be less than the requested amount due to integer arithmetic,
     *      or because unbonding a node's full allocation would leave it below the precompile dust threshold.
     *      The remaining amount, or 'dust' is scheduled to be unbonded in the next batch.
     *      In this scenario, `totalPooled` is temporarily increased by this dust amount to account for the assets
     *      that were requested to be unbonded but were not unbonded from nodes, ensuring they remain trackable
     *      in the pool for the next attempt.
     */
    function submitBatch() external whenNotPaused {
        _updateFees();

        uint96 _totalPooled = totalPooled; // shadow
        uint40 _currentBatchId = currentBatchId; // shadow

        (uint64 currentEpoch, uint64 activityEpoch) = _getActivityEpoch();

        // Use previous batch submission as starting point
        // If this is the first batch, the "previous batch submission" will contain the default values of 0
        BatchSubmission memory batchSubmission = batchSubmissions[_currentBatchId - 1];

        if (currentEpoch < batchSubmission.activationEpoch) revert MinimumBatchDelay();

        Batch memory batchDepositRequest = batchDepositRequests[_currentBatchId];
        Batch memory batchWithdrawRequest = batchWithdrawRequests[_currentBatchId];

        uint96 dustEgress;
        if (batchDepositRequest.assets > batchWithdrawRequest.assets) {
            // Net ingress
            uint96 bondedAmountEvm = _doBonding(batchDepositRequest.assets, batchWithdrawRequest.assets, _totalPooled);
            uint96 dust = batchDepositRequest.assets - batchWithdrawRequest.assets - bondedAmountEvm;
            if (dust > 0) {
                batchDepositRequests[_currentBatchId + 1].assets = dust;
            }
            batchSubmission.activationEpoch = activityEpoch;
        } else if (batchWithdrawRequest.assets > batchDepositRequest.assets) {
            // Net egress
            uint96 unbondedAmountEvm = _doUnbonding(batchWithdrawRequest.assets, batchDepositRequest.assets, _totalPooled);
            dustEgress = batchWithdrawRequest.assets - batchDepositRequest.assets - unbondedAmountEvm;
            if (dustEgress > 0) {
                batchWithdrawRequests[_currentBatchId + 1].assets = dustEgress;
                _totalPooled += dustEgress;
            }
            batchSubmission.activationEpoch = activityEpoch;
        } else {
            // Net neutral (deposits == withdrawals)
            if (batchDepositRequest.assets == 0) revert EmptyBatch();
            batchSubmission.activationEpoch = currentEpoch;
        }

        if (batchWithdrawRequest.shares > 0) {
            ERC20Upgradeable._burn(address(this), batchWithdrawRequest.shares);
        }

        if (batchWithdrawRequest.assets > 0) {
            // Always decrement `totalPooled` by the batched withdraw assets
            // `_totalPooled` is offset by dust if unbonding is performed above
            totalPooled = _totalPooled - batchWithdrawRequest.assets;
        }

        // Convert escrow shares into protocol shares
        ExitFee memory _exitFee = exitFee; // shadow (SLOAD 1 slot)
        if (_exitFee.escrowShares > 0) {
            _exitFee.protocolShares += _exitFee.escrowShares;
            _exitFee.escrowShares = 0;
            exitFee = _exitFee;
        }

        // Update current batch submission blocks
        batchSubmission.submissionEpoch = currentEpoch;
        batchSubmissions[_currentBatchId] = batchSubmission;

        // Increment batch id
        currentBatchId = _currentBatchId + 1;

        emit BatchSent(_currentBatchId, batchWithdrawRequest.shares, batchWithdrawRequest.assets - dustEgress);
    }

    /**
     * @notice Forcibly unbonds funds from a disabled node
     * @dev This function is for emergency/cleanup purposes and does not depend on the standard batching process
     * @dev Does NOT decrease `totalPooled` because funds never leave the protocol's custody
     * @dev Funds will be scheduled for redelegation during `sweepForced()`
     * @param nodeId - ID of the disabled node to unbond from
     */
    function unbondDisableNode(uint64 nodeId) external whenNotPaused onlyRole(ROLE_REMOVE_NODE) {
        if (!isNodeDisabled[nodeId]) revert ActiveNode();

        Node storage node = Registry.getNodeByNodeId(nodeId);
        uint96 _staked = node.staked;
        if (_staked == 0) revert NoChange();

        // Directly call undelegate on the Staker precompile.
        StakerUpgradeable.undelegateForced(nodeId, _staked);

        // Immediately update storage to reflect the unbonding.
        node.staked = 0;
    }

    /**
     * @notice Withdraws MON from completed un-delegations
     * @notice Stores withdrawn funds in the contract to fund redemptions
     * @dev Required number of epochs must have passed since calling `undelegate`
     * @dev All withdrawals must be valid and complete or none will
     */
    function sweep(uint64[] memory nodeIds, uint8 maxWithdrawsPerNode) external whenNotPaused {
        uint256 len = nodeIds.length;
        for (uint64 i; i < len; ++i) {
            StakerUpgradeable.withdraw(nodeIds[i], maxWithdrawsPerNode);
        }
    }

    /**
     * @notice Withdraws MON from completed un-delegations of disabled nodes
     * @notice Adds withdrawn funds into the current batch to be redelegated
     * @dev Required number of epochs must have passed since calling `undelegate`
     * @dev All withdrawals must be valid and complete or none will
     */
    function sweepForced(uint64[] memory nodeIds) external whenNotPaused {
        uint256 balanceSnapshot = address(this).balance;

        uint256 len = nodeIds.length;
        for (uint64 i; i < len; ++i) {
            StakerUpgradeable.withdrawForced(nodeIds[i]);
        }

        uint256 amountWithdrawn = address(this).balance - balanceSnapshot;
        if (amountWithdrawn > 0) {
            batchDepositRequests[currentBatchId].assets += uint96(amountWithdrawn);
        }
    }

    /**
     * @notice Claims all claimable rewards and adds them to the next batch
     * @dev Specifying an invalid node id will revert
     */
    function compound(uint64[] memory nodeIds) external whenNotPaused {
        uint256 claimedRewards;
        uint256 balanceSnapshot = address(this).balance;

        uint256 len = nodeIds.length;
        for (uint64 i; i < len; ++i) {
            StakerUpgradeable.claimRewards(nodeIds[i]);
            uint256 nodeRewards = address(this).balance - balanceSnapshot - claimedRewards;
            if (nodeRewards > 0) {
                claimedRewards += nodeRewards;
                emit Compounded(nodeIds[i], nodeRewards);
            }
        }

        if (claimedRewards == 0) revert NoChange();

        totalPooled += uint96(claimedRewards);
        batchDepositRequests[currentBatchId].assets += uint96(claimedRewards);
    }

    /**
     * @notice Allows external funds to be added without minting shares
     * @dev Restricts usage when total pooled is below a threshold to prevent share inflation attacks
     * @param benefactor - Address used for tracking who is responsible for the contribution
     */
    function contributeToPool(address benefactor) external payable whenNotPaused {
        if (msg.value > type(uint96).max) revert DepositOverflow();
        uint96 _totalPooled = totalPooled; // shadow
        if (_totalPooled < MINIMUM_CONTRIBUTE_THRESHOLD) revert MinimumContributeThreshold();
        totalPooled = _totalPooled + uint96(msg.value);
        batchDepositRequests[currentBatchId].assets += uint96(msg.value);
        emit Contribution(msg.value, benefactor);
    }

    /*
     * @notice Distributes all protocol fees
     * @notice Mints management fees if present
     * @notice Transfers exit fees if present
     */
    function claimProtocolFees(address to) external whenNotPaused onlyRole(ROLE_FEE_CLAIMER) {
        _updateFees();

        uint256 managementFeeShares = managementFee.virtualSharesSnapshot;
        if (managementFeeShares > 0) {
            ERC20Upgradeable._mint(to, managementFeeShares);
            managementFee.virtualSharesSnapshot = 0;
        }

        uint256 exitFeeShares = exitFee.protocolShares;
        if (exitFeeShares > 0) {
            ERC20Upgradeable._transfer(address(this), to, exitFeeShares);
            exitFee.protocolShares = 0;
        }

        emit FeesWithdrawn(managementFeeShares, exitFeeShares);
    }

    function setManagementFee(uint16 newFee) external onlyRole(ROLE_FEE_SETTER) {
        if (newFee > 2_00) revert FeeTooLarge();
        if (newFee == managementFee.bips) revert NoChange();
        _updateFees();
        managementFee.bips = newFee;
        emit ManagementFeeAdjusted(newFee);
    }

    function setExitFee(uint16 newFee) external onlyRole(ROLE_FEE_SETTER) {
        if (newFee > 50) revert FeeTooLarge();
        if (newFee == exitFee.bips) revert NoChange();
        exitFee.bips = newFee;
        emit ExitFeeAdjusted(newFee);
    }

    function setExitFeeExemption(address user, bool isExempt) external onlyRole(ROLE_FEE_EXEMPTION) {
        isExitFeeExempt[user] = isExempt;
    }

    /**
     * @notice Pause the protocol: deposits, unlocks, cancellations, batches, redemptions, sweeps and fee claims
     * @notice Holder-to-holder transfers keep working; see `pauseTransfers()` and `pauseProtocolAndTransfers()`
     * @dev Read the state with `protocolPaused()` (or OpenZeppelin's `paused()`)
     */
    function pauseProtocol() external onlyRole(ROLE_PAUSE) {
        PausableUpgradeable._pause();
    }

    /**
     * @notice Pause the protocol and holder-to-holder transfers in one call
     * @dev Sets whichever of the two is not already set; reverts with `NoChange` only if both already are
     * @dev Each is resumed separately, with `unpauseProtocol()` and `unpauseTransfers()`
     */
    function pauseProtocolAndTransfers() external onlyRole(ROLE_PAUSE) {
        bool isProtocolPaused = PausableUpgradeable.paused();
        bool isTransfersPaused = TransferPausableUpgradeable.transfersPaused();
        if (isProtocolPaused && isTransfersPaused) revert NoChange();

        if (!isProtocolPaused) PausableUpgradeable._pause();
        if (!isTransfersPaused) TransferPausableUpgradeable._pauseTransfers();
    }

    /**
     * @dev Separate from ROLE_PAUSE: pausing only protects, but unpausing mid-incident lets an attacker move or
     *      redeem again, so it can be kept on a higher-trust key than the pauser
     */
    function unpauseProtocol() external onlyRole(ROLE_UNPAUSE) {
        PausableUpgradeable._unpause();
    }

    /**
     * @notice Move the entire sMON balance of a frozen account to `to`
     * @dev Shares are transferred, never burnt: burning would raise the redemption ratio for every other holder
     *      instead of returning value to whoever was robbed
     * @dev Works while paused
     * @dev `to` should be a fresh address. Returning funds to a wallet that still carries the thief's approvals
     *      or delegations lets them be taken again.
     */
    function seizeBalance(address account, address to) external onlyRole(ROLE_SEIZE) {
        _requireSeizable(account, to);

        uint256 shares = ERC20Upgradeable.balanceOf(account);
        if (shares == 0) revert NoChange();

        // Call the base implementation directly to bypass the freeze check in `_update()`
        ERC20Upgradeable._update(account, to, shares);

        emit Seized(account, to, shares);
    }

    /**
     * @notice Take over one unlock request of a frozen account
     * @notice A request still in the open batch is cancelled and its shares (exit fee included) go to `to`
     * @notice A request whose batch was already submitted (unbonding) moves to `to`, who redeems it as usual
     * @dev Works while paused, although redeeming a reassigned request still requires the contract to be unpaused
     * @dev Order of the frozen account's unlock requests is not preserved, as with cancellations
     */
    function seizeUnlockRequest(address account, uint256 unlockIndex, address to) external onlyRole(ROLE_SEIZE) {
        _requireSeizable(account, to);

        // Intentional panic on out-of-bounds access, as it's more gas-efficient than an explicit length check
        UnlockRequest[] storage userUnlockRequestArray = userUnlockRequests[account];
        UnlockRequest memory userUnlockRequest = userUnlockRequestArray[unlockIndex]; // shadow (SLOAD 1 slot)

        if (userUnlockRequest.batchId == currentBatchId) {
            // Batch not submitted yet: cancel the request and hand its escrowed shares to `to`
            uint96 shares = _removeOpenUnlockRequest(account, unlockIndex);

            // Call the base implementation directly to bypass the freeze check in `_update()`
            ERC20Upgradeable._update(address(this), to, shares);

            emit UnlockRequestSeized(account, unlockIndex, to, shares, userUnlockRequest.spotValue, false);
        } else {
            // Batch submitted: shares are already burnt and MON is unbonding, so `to` takes over the claim
            _deleteUnlockRequest(userUnlockRequestArray, unlockIndex);
            userUnlockRequests[to].push(userUnlockRequest);

            emit UnlockRequestSeized(account, unlockIndex, to, userUnlockRequest.shares, userUnlockRequest.spotValue, true);
        }
    }

    /**
     * @dev Blocked while transfers are paused. Protocol flows move shares with internal calls and are governed by
     *      the protocol pause instead. Any new entrypoint that moves sMON between holders must also call
     *      `_requireTransfersNotPaused()`.
     */
    function transfer(address to, uint256 value) public override returns (bool) {
        TransferPausableUpgradeable._requireTransfersNotPaused();
        return ERC20Upgradeable.transfer(to, value);
    }

    /// @dev See `transfer()`
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        TransferPausableUpgradeable._requireTransfersNotPaused();
        return ERC20Upgradeable.transferFrom(from, to, value);
    }

    /**
     * @dev Every sMON transfer, mint and burn passes through here
     * @dev Freeze check blocks frozen senders and recipients. There is no pause check here: every protocol path
     *      that mints, burns or moves shares is `whenNotPaused`, and holder transfers are gated by the transfer
     *      pause in `transfer()` / `transferFrom()`.
     * @dev `seizeBalance()` and `seizeUnlockRequest()` call `ERC20Upgradeable._update()` directly to skip the freeze check
     */
    function _update(address from, address to, uint256 value) internal override {
        _requireNotFrozen(from);
        _requireNotFrozen(to);
        ERC20Upgradeable._update(from, to, value);
    }

    /**
     * @dev A frozen account cannot be granted a new allowance, but anyone may still set an allowance to zero,
     *      so holders can revoke approvals they gave to a frozen account
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal override {
        if (value > 0) {
            _requireNotFrozen(owner);
            _requireNotFrozen(spender);
        }
        ERC20Upgradeable._approve(owner, spender, value, emitEvent);
    }

    /// @dev A frozen spender cannot use allowances it was given before it was frozen
    function _spendAllowance(address owner, address spender, uint256 value) internal override {
        _requireNotFrozen(spender);
        ERC20Upgradeable._spendAllowance(owner, spender, value);
    }

    function _getActivityEpoch() private returns (uint64 currentEpoch, uint64 activityEpoch) {
        (uint64 _currentEpoch, bool in_epoch_delay_period) = StakerUpgradeable.getEpoch();
        currentEpoch = _currentEpoch;
        activityEpoch = in_epoch_delay_period ? currentEpoch + 2 : currentEpoch + 1;
    }

    /*
     * @dev Applies a bips fee and rounds up
     * @dev When `feeInBips` is zero, returned fee will also be zero
     * @dev When `feeInBips` is non-zero, returned fee will always be non-zero
     */
    function _calculateFee(uint256 amount, uint256 feeInBips) private pure returns (uint96) {
        return uint96((amount * feeInBips + (BIPS - 1)) / BIPS); // round up
    }

    /**
     * @dev Calculates differences between current staked amounts and optimal staked amounts
     * @return totalExcess - Total excess stake of all nodes; zero indicates no excess
     * @return totalDeficit - Total deficit stake of all nodes; zero indicates no deficit
     * @return nodeExcesses - Excess stake (if any) for each node; zero indicates equilibrium or deficit
     * @return nodeDeficits - Deficit stake (if any) for each node; zero indicates equilibrium or excess
     */
    function _calculateStakeDeltas(
        Node[] memory nodes,
        uint256 targetTotalStaked
    ) private view returns (
        uint96 totalExcess,
        uint96 totalDeficit,
        uint96[] memory nodeExcesses,
        uint96[] memory nodeDeficits
    ) {
        uint256 _totalWeight = Registry.totalWeight; // shadow

        uint256 len = nodes.length;
        nodeExcesses = new uint96[](len);
        nodeDeficits = new uint96[](len);

        for (uint256 i; i < len; ++i) {
            uint256 stakedAmountCurrent = nodes[i].staked;
            uint256 stakedAmountOptimal = _totalWeight > 0 ? targetTotalStaked * uint256(nodes[i].weight) / _totalWeight : 0;

            if (stakedAmountCurrent > stakedAmountOptimal) {
                // Excess / Over allocation
                uint256 diff = stakedAmountCurrent - stakedAmountOptimal;
                totalExcess += uint96(diff);
                nodeExcesses[i] = uint96(diff);
            } else if (stakedAmountOptimal > stakedAmountCurrent) {
                // Deficit / Under allocation
                uint256 diff = stakedAmountOptimal - stakedAmountCurrent;
                totalDeficit += uint96(diff);
                nodeDeficits[i] = uint96(diff);
            }
        }
    }

    /**
     * @dev Delegates to multiple nodes moving stake distribution towards the current Registry weights
     * @dev Does NOT update `totalPooled`
     * @dev Total staked can be derived from totalPooled, batchDeposits, batchWithdrawals as:
     *      totalStaked = totalPooled - batchDeposits;
     *      totalBeingBonded = batchDeposits - batchWithdrawals;
     *      newTotalStaked = totalStaked + totalBeingBonded;
     *                     = (totalPooled - batchDeposits) + (batchDeposits - batchWithdrawals);
     *                     = totalPooled - batchDeposits + batchDeposits - batchWithdrawals;
     *                     = totalPooled - batchWithdrawals;
     */
    function _doBonding(uint96 batchDeposits, uint96 batchWithdrawals, uint96 _totalPooled) private returns (uint96 actualBonding) {
        uint256 _totalWeight = Registry.totalWeight; // shadow
        if (_totalWeight == 0) revert ZeroTotalWeight();

        // Every node's share is at most the total, so nothing can reach the dust threshold
        uint256 requestedBonding = batchDeposits - batchWithdrawals;
        if (requestedBonding < DUST_THRESHOLD) return 0;

        Node[] memory _nodes = Registry.nodes; // shadow (SLOAD n-nodes slots)
        (, uint96 totalDeficit,, uint96[] memory nodeDeficits) = _calculateStakeDeltas(
            _nodes,
            _totalPooled - batchWithdrawals // derived newTotalStaked
        );

        if (totalDeficit == 0) return 0;

        uint256 n = _nodes.length;
        for (uint256 i; i < n; ++i) {
            uint96 bondAmount = uint96(requestedBonding * nodeDeficits[i] / totalDeficit);

            // Precompile rejects delegations below the dust threshold
            // Leave the amount as dust for the next batch
            if (bondAmount >= DUST_THRESHOLD) {
                Registry.nodes[i].staked = _nodes[i].staked + bondAmount;
                StakerUpgradeable.delegate(_nodes[i].id, bondAmount);
                actualBonding += bondAmount;
            }
        }
    }

    /**
     * @dev Undelegates from multiple nodes moving stake distribution towards the current Registry weights
     * @dev Does NOT update `totalPooled`
     * @dev Total staked can be derived from totalPooled, batchDeposits, batchWithdrawals as:
     *      totalStaked = totalPooled - batchDeposits;
     *      totalBeingUnbonded = batchWithdrawals - batchDeposits;
     *      newTotalStaked = totalStaked - totalBeingUnbonded;
     *                     = (totalPooled - batchDeposits) - (batchWithdrawals - batchDeposits);
     *                     = totalPooled - batchDeposits - batchWithdrawals + batchDeposits;
     *                     = totalPooled - batchWithdrawals;
     */
    function _doUnbonding(uint96 batchWithdrawals, uint96 batchDeposits, uint96 _totalPooled) private returns (uint96 actualUnbonding) {
        Node[] memory _nodes = Registry.nodes; // shadow (SLOAD n-nodes slots)
        (uint96 totalExcess,, uint96[] memory nodeExcesses,) = _calculateStakeDeltas(
            _nodes,
            _totalPooled - batchWithdrawals // derived newTotalStaked
        );

        uint256 requestedUnbonding = batchWithdrawals - batchDeposits;

        uint256 n = _nodes.length;
        for (uint256 i; i < n; ++i) {
            uint96 unbondAmount = uint96(requestedUnbonding * nodeExcesses[i] / totalExcess);

            // Prevent leaving a remainder below the dust threshold
            // The shortfall rolls forward as dust to be unbonded next batch
            uint96 remainder = _nodes[i].staked - unbondAmount;
            if (remainder > 0 && remainder < DUST_THRESHOLD) {
                unbondAmount = _nodes[i].staked - DUST_THRESHOLD;
            }

            if (unbondAmount > 0) {
                Registry.nodes[i].staked = _nodes[i].staked - unbondAmount;
                actualUnbonding += unbondAmount;
                StakerUpgradeable.undelegate(_nodes[i].id, unbondAmount);
            }
        }
    }

    /**
     * @dev Seizing requires a frozen source and an unfrozen recipient other than the zero address or this contract
     * @dev Those two can never be frozen, so they need an explicit check. `to == account` needs none: `account` is
     *      frozen, so `_requireNotFrozen(to)` rejects it
     */
    function _requireSeizable(address account, address to) private view {
        _requireFrozen(account);
        if (to == address(0) || to == address(this)) revert InvalidAccount();
        _requireNotFrozen(to);
    }

    /**
     * @dev Removes an unlock request whose batch is still open and reverses its accounting
     * @dev Returns the shares (exit fee included) the contract now owes back; the caller decides where they go
     */
    function _removeOpenUnlockRequest(address account, uint256 unlockIndex) private returns (uint96 shares) {
        // Intentional panic on out-of-bounds access, as it's more gas-efficient than an explicit length check
        UnlockRequest[] storage userUnlockRequestArray = userUnlockRequests[account];
        UnlockRequest memory userUnlockRequest = userUnlockRequestArray[unlockIndex]; // shadow (SLOAD 1 slot)
        if (userUnlockRequest.batchId != currentBatchId) revert CancellationWindowClosed();

        // Re-calculate the shares breakdown used during `requestUnlock()`
        uint96 sharesToFee = _calculateFee(userUnlockRequest.shares, userUnlockRequest.exitFeeInBips);
        uint96 sharesToUnlock = userUnlockRequest.shares - sharesToFee;

        // Remove shares from current batch unlock request
        Batch memory _batchWithdrawRequest = batchWithdrawRequests[userUnlockRequest.batchId]; // shadow (SLOAD 1 slot)
        _batchWithdrawRequest.assets -= userUnlockRequest.spotValue;
        _batchWithdrawRequest.shares -= sharesToUnlock;
        batchWithdrawRequests[userUnlockRequest.batchId] = _batchWithdrawRequest;

        // Remove shares from escrow
        if (sharesToFee > 0) {
            exitFee.escrowShares -= sharesToFee;
        }

        // Delete the cancelled unlock request
        _deleteUnlockRequest(userUnlockRequestArray, unlockIndex);

        shares = userUnlockRequest.shares;
    }

    /**
     * @dev Helper method to effectively remove an array element
     * @dev Calling method should check that array.length > 0
     */
    function _deleteUnlockRequest(UnlockRequest[] storage array, uint256 index) private {
        uint256 finalIndex = array.length - 1;
        if (index != finalIndex) {
            // Replace the element being removed with the last element
            // Not needed if removing the last element (array.length == 1)
            array[index] = array[finalIndex];
        }
        // Remove the last element
        array.pop();
    }

    /**
     * @dev Calculates summation of management fees from last update until now
     * @dev Must be called before changing total supply, virtual shares, or management fee
     * @dev Must be called before calculating redemption ratio
     */
    function _updateFees() private {
        ManagementFee memory _managementFee = managementFee; // shadow (SLOAD 1 slot)
        uint256 time = block.timestamp - _managementFee.lastUpdate;
        if (time > 0) {
            uint256 feeShares = _calculateFee(ERC20Upgradeable.totalSupply() + _managementFee.virtualSharesSnapshot, _managementFee.bips);
            uint256 feeSharesTimeWeighted = feeShares * time / YEAR;
            _managementFee.virtualSharesSnapshot = uint96(_managementFee.virtualSharesSnapshot + feeSharesTimeWeighted);
            _managementFee.lastUpdate = uint40(block.timestamp);
            managementFee = _managementFee;

            emit VirtualSharesSnapshot(_managementFee.virtualSharesSnapshot);
        }
    }
}
