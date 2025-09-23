// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./precompile/Staker.sol";
import "./CustomErrors.sol";
import "./Registry.sol";

/**
 * @title StakedMonad
 * @author Brandon Mino <https://github.com/bmino>
 * @notice Core liquid staking contract for MON, allowing users to deposit MON to receive sMON shares
 *         Manages the lifecycle of staking, un-staking, and rewards distribution
 *         Facilitates batch processing of deposits and withdrawals
 *         Dynamically adjusts bonding/unbonding node allocation based on Registry weights
 */
contract StakedMonad is CustomErrors, Registry, Staker, UUPSUpgradeable, ERC20Upgradeable, AccessControlUpgradeable, PausableUpgradeable {
    uint16 private constant BIPS = 100_00;
    uint40 private constant YEAR = 365 days;

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
    event BatchSent(uint256 batchId, uint256 shares, uint256 spotValue);
    event Sync(uint256 rewarded, uint256 slashed);
    event Contribution(uint256 amount, address benefactor);
    event FeesWithdrawn(uint256 managementFeeShares, uint256 exitFeeShares);
    event ManagementFeeAdjusted(uint256 newFee);
    event ExitFeeAdjusted(uint256 newFee);

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
    bytes32 public constant ROLE_TOGGLE_INSTANT_UNLOCK = keccak256("ROLE_TOGGLE_INSTANT_UNLOCK");

    uint256 public constant MINIMUM_CONTRIBUTE_THRESHOLD = 5_000 ether;

    // Total MON under management: batched deposits, staked, but excluding MON being unbonded
    uint96 public totalPooled;

    /// @dev Tracks the current batch being populated. Initialized to 1
    uint40 public currentBatchId;

    /// @dev Flag for allowing instant unlocks
    bool public isInstantUnlockEnabled;

    ExitFee private exitFee;
    ManagementFee private managementFee;

    mapping(address => bool) public isExitFeeExempt;
    mapping(uint256 => BatchSubmission) public batchSubmissions;
    mapping(uint256 => Batch) public batchDepositRequests;
    mapping(uint256 => Batch) public batchWithdrawRequests;
    mapping(address => UnlockRequest[]) public userUnlockRequests;

    // Allow receiving funds via sweep()
    receive() external payable {}

    function initialize(address admin) external payable initializer {
        UUPSUpgradeable.__UUPSUpgradeable_init();
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
        AccessControlUpgradeable._grantRole(ROLE_TOGGLE_INSTANT_UNLOCK, admin);

        currentBatchId = 1;
        isInstantUnlockEnabled = true;

        managementFee = ManagementFee({
            bips: 2_00, // initial fee of 2.00%
            virtualSharesSnapshot: 0,
            lastUpdate: uint40(block.timestamp)
        });
        exitFee.bips = 5; // initial fee of 0.05%
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ROLE_UPGRADE) {}

    function _authorizeAddNode() internal view override onlyRole(ROLE_ADD_NODE) {}
    function _authorizeUpdateWeight() internal view override onlyRole(ROLE_UPDATE_WEIGHTS) {}
    function _authorizeDisableNode() internal view override onlyRole(ROLE_DISABLE_NODE) {}
    function _authorizeRemoveNode(uint64 nodeId) internal view override onlyRole(ROLE_REMOVE_NODE) {
        if (Staker.getWithdrawIdsSize(nodeId) > 0) revert PendingWithdrawals();
        if (Staker.isForceWithdrawPending(nodeId)) revert PendingWithdrawals();
    }

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

    /**
     * @notice Shares that can be unlocked instantly at the current block
     * @dev This function will technically under report unlockable shares when exit fees are present
            due to the fee shares not being undelegated and therefore not matched with pending deposits
     */
    function getInstantUnlockableShares() external view returns (uint96) {
        if (!isInstantUnlockEnabled) return 0;
        return convertToShares(batchDepositRequests[currentBatchId].assets);
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
            uint256 feeShares = (ERC20Upgradeable.totalSupply() + shares) * _managementFee.bips / BIPS;
            uint256 feeSharesTimeWeighted = feeShares * time / YEAR;
            shares += uint96(feeSharesTimeWeighted);
        }
    }

    function getImbalances(uint96 newTotalStaked) external view returns (
        uint96 overAllocation,
        uint96 underAllocation,
        uint96[] memory overAllocations,
        uint96[] memory underAllocations
    ) {
        return _getImbalances(Registry.nodes, newTotalStaked);
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
    }

    /**
     * @notice Redeems shares for assets immediately if sufficient deposits are pending
     * @notice Applies the exit fee if present
     * @dev Can be globally disabled by ROLE_TOGGLE_INSTANT_UNLOCK
     * @dev Might need to first call `sweep()`
     */
    function instantUnlock(uint96 shares, uint96 minSpotValue, address receiver) external returns (uint96 spotValue) {
        if (!isInstantUnlockEnabled) revert InstantUnlockDisabled();

        _updateFees();

        // Calculate exit toll (if any)
        uint96 sharesToFee = isExitFeeExempt[msg.sender] ? 0 : uint96(uint256(shares) * exitFee.bips / BIPS);

        uint96 sharesToUnlock = shares - sharesToFee;
        spotValue = convertToAssets(sharesToUnlock);

        if (spotValue == 0) revert NoChange();
        if (spotValue < minSpotValue) revert MinimumUnlock();

        Batch storage batchDepositRequest = batchDepositRequests[currentBatchId];
        uint96 _batchAssets = batchDepositRequest.assets; // shadow

        if (spotValue > _batchAssets) revert InstantUnlockThreshold();

        // Remove instantly redeemed assets from current batch
        batchDepositRequest.assets = _batchAssets - spotValue;

        // Directly transfer all shares avoiding need for approval
        ERC20Upgradeable._transfer(msg.sender, address(this), shares);

        // Burn shares that will be instantly redeemed
        ERC20Upgradeable._burn(address(this), sharesToUnlock);

        // Claim protocol shares skipping escrow
        if (sharesToFee > 0) {
            exitFee.protocolShares += sharesToFee;
        }

        // Instantly redeem
        (bool success,) = receiver.call{value: spotValue}("");
        if (!success) revert TransferFailed();
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
            sharesToFee = uint96(uint256(shares) * exitFeeInBips / BIPS);
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
        // Intentional panic on out-of-bounds access, as it's more gas-efficient than an explicit length check
        UnlockRequest[] storage userUnlockRequestArray = userUnlockRequests[msg.sender];
        UnlockRequest memory userUnlockRequest = userUnlockRequestArray[unlockIndex]; // shadow (SLOAD 1 slot)
        if (userUnlockRequest.batchId != currentBatchId) revert CancellationWindowClosed();

        // Re-calculate the shares breakdown used during `requestUnlock()`
        uint96 sharesToFee = uint96(uint256(userUnlockRequest.shares) * userUnlockRequest.exitFeeInBips / BIPS);
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

        // Delete user's cancelled unlock request
        _deleteUnlockRequest(userUnlockRequestArray, unlockIndex);

        // Return shares to caller
        ERC20Upgradeable._transfer(address(this), msg.sender, userUnlockRequest.shares);

        emit UnlockCancelled(msg.sender, unlockIndex);
    }

    /**
     * @notice Step 2 of 2 in process of withdrawing assets
     * @notice Returns original deposit amount plus interest
     * @notice Associated batch must have been submitted and the cooldown period elapsed
     * @dev Might need to first call `sweep()`
     * @dev Deletes the caller's unlock request
     */
    function redeem(uint256 unlockIndex, address payable receiver) external whenNotPaused returns (uint96 assets) {
        UnlockRequest[] storage userUnlockRequestArray = userUnlockRequests[msg.sender];
        UnlockRequest memory userUnlockRequest = userUnlockRequestArray[unlockIndex]; // shadow (SLOAD 1 slot)
        BatchSubmission memory batchSubmission = batchSubmissions[userUnlockRequest.batchId]; // shadow (SLOAD 1 slot)
        if (batchSubmission.submissionEpoch == 0) revert BatchNotSubmitted();

        (uint64 currentEpoch,) = Staker.getEpoch();
        if (currentEpoch < batchSubmission.activationEpoch + Staker.getWithdrawDelay()) revert WithdrawDelay();

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
            uint96 dust = batchWithdrawRequest.assets - batchDepositRequest.assets - unbondedAmountEvm;
            if (dust > 0) {
                batchWithdrawRequests[_currentBatchId + 1].assets = dust;
                _totalPooled += dust;
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
    }

    /**
     * @notice Forcibly unbonds funds from a disabled node
     * @dev This function is for emergency/cleanup purposes and does not depend on the standard batching process
     * @param nodeId - ID of the disabled node to unbond from
     */
    function unbondDisableNode(uint64 nodeId) external whenNotPaused onlyRole(ROLE_REMOVE_NODE) {
        if (!isNodeDisabled[nodeId]) revert ActiveNode();

        Node storage node = Registry.getNodeByNodeId(nodeId);
        uint96 _staked = node.staked;
        if (_staked == 0) revert NoChange();

        // Directly call undelegate on the Staker precompile.
        Staker.undelegateForced(nodeId, _staked);

        // Immediately update storage to reflect the unbonding.
        node.staked = 0;

        // We also need to remove the unbonded amount from totalPooled
        // as it's no longer "pooled" for staking.
        // The funds are now in a "pending unbond" state.
        totalPooled -= _staked;
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
            Staker.withdraw(nodeIds[i], maxWithdrawsPerNode);
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
            Staker.withdrawForced(nodeIds[i]);
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
        uint256 balanceBefore = address(this).balance;

        uint256 len = nodeIds.length;
        for (uint64 i; i < len; ++i) {
            Staker.claimRewards(nodeIds[i]);
        }

        uint256 claimedRewards = address(this).balance - balanceBefore;
        if (claimedRewards == 0) revert NoChange();

        totalPooled += uint96(claimedRewards);
        batchDepositRequests[currentBatchId].assets += uint96(claimedRewards);
    }

    /**
     * @notice Syncs the staking metrics with precompile to socialize slashing
     * @dev Updates `totalPooled` and `Registry.node[].staked`
     */
    function syncStaking() external whenNotPaused {
        uint96 rewards;
        uint96 slashed;

        uint256 n = Registry.nodes.length;
        for (uint256 i; i < n; ++i) {
            Node storage node = Registry.nodes[i];
            Node memory _node = node; // shadow (SLOAD 1 slot)
            (
                uint256 stake,
                /* uint256 acc_reward_per_token */,
                /* uint256 rewards */,
                uint256 delta_stake,
                uint256 next_delta_stake,
                /* uint256 delta_epoch */,
                /* uint256 next_delta_epoch */
            ) = Staker.getDelegator(_node.id, address(this));
            uint96 oldStake = _node.staked;
            uint96 newStake = uint96(stake + delta_stake + next_delta_stake);

            if (newStake > oldStake) {
                // Compound
                rewards += newStake - oldStake;
                node.staked = newStake;
            } else if (newStake < oldStake) {
                // Slash
                slashed += oldStake - newStake;
                node.staked = newStake;
            }
        }

        if (rewards > 0 || slashed > 0) {
            totalPooled = totalPooled + rewards - slashed;
        }

        emit Sync(rewards, slashed);
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

    function setInstantUnlock(bool isEnabled) external onlyRole(ROLE_TOGGLE_INSTANT_UNLOCK) {
        isInstantUnlockEnabled = isEnabled;
    }

    function pause() external onlyRole(ROLE_PAUSE) {
        PausableUpgradeable._pause();
    }

    function unpause() external onlyRole(ROLE_PAUSE) {
        PausableUpgradeable._unpause();
    }

    function _getActivityEpoch() private view returns (uint64 currentEpoch, uint64 activityEpoch) {
        (uint64 _currentEpoch, bool in_epoch_delay_period) = Staker.getEpoch();
        currentEpoch = _currentEpoch;
        activityEpoch = in_epoch_delay_period ? currentEpoch + 2 : currentEpoch + 1;
    }

    /**
     * @dev Calculates differences between current staked amounts and optimal staked amounts
     * @return overAllocation - Total over allocations of all nodes; zero indicates no over-allocations
     * @return underAllocation - Total under allocations of all nodes; zero indicates no under-allocations
     * @return overAllocations - Over allocation (if any) for each node; zero indicates equilibrium or under-allocation
     * @return underAllocations - Under allocation (if any) for each node; zero indicates equilibrium or over-allocation
     */
    function _getImbalances(
        Node[] memory nodes,
        uint256 newTotalStaked
    ) private view returns (
        uint96 overAllocation,
        uint96 underAllocation,
        uint96[] memory overAllocations,
        uint96[] memory underAllocations
    ) {
        uint256 _totalWeight = Registry.totalWeight; // shadow

        uint256 len = nodes.length;
        overAllocations = new uint96[](len);
        underAllocations = new uint96[](len);

        for (uint256 i; i < len; ++i) {
            uint256 stakedAmountCurrent = nodes[i].staked;
            uint256 stakedAmountOptimal = _totalWeight > 0 ? uint256(nodes[i].weight) * newTotalStaked / _totalWeight : 0;

            if (stakedAmountCurrent > stakedAmountOptimal) {
                // Over allocation
                uint256 diff = stakedAmountCurrent - stakedAmountOptimal;
                overAllocation += uint96(diff);
                overAllocations[i] = uint96(diff);
            } else if (stakedAmountOptimal > stakedAmountCurrent) {
                // Under allocation
                uint256 diff = stakedAmountOptimal - stakedAmountCurrent;
                underAllocation += uint96(diff);
                underAllocations[i] = uint96(diff);
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

        Node[] memory _nodes = Registry.nodes; // shadow (SLOAD n-nodes slots)
        (, uint96 underAllocation,, uint96[] memory underAllocations) = _getImbalances(
            _nodes,
            _totalPooled - batchWithdrawals // derived newTotalStaked
        );

        uint256 requestedBonding = batchDeposits - batchWithdrawals;

        // Amount to distribute to under-allocated nodes
        uint256 phase1 = requestedBonding < underAllocation ? requestedBonding : underAllocation;

        // Remaining amount to distribute equitably to all nodes
        uint256 phase2 = requestedBonding - phase1;

        uint256 n = _nodes.length;
        for (uint256 i; i < n; ++i) {
            // Phase 1: Prioritize under-allocated nodes
            // Distribute proportionally based on how much each node is under their target
            uint256 phase1Amount = underAllocations[i] > 0
                ? phase1 * underAllocations[i] / underAllocation
                : 0;

            // Phase 2: Distribute remaining funds equitably
            // Allocate based on each node's relative weight in the network
            uint256 phase2Amount = phase2 > 0
                ? phase2 * _nodes[i].weight / _totalWeight
                : 0;

            uint96 bondAmount = uint96(phase1Amount + phase2Amount);

            if (bondAmount > 0) {
                Registry.nodes[i].staked = _nodes[i].staked + bondAmount;
                Staker.delegate(_nodes[i].id, bondAmount);
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
        (uint96 overAllocation,, uint96[] memory overAllocations,) = _getImbalances(
            _nodes,
            _totalPooled - batchWithdrawals // derived newTotalStaked
        );

        uint256 requestedUnbonding = batchWithdrawals - batchDeposits;

        // Amount to withdraw from over-allocated nodes
        uint256 phase1 = requestedUnbonding < overAllocation ? requestedUnbonding : overAllocation;

        // Remaining amount to withdraw equitably from all nodes
        uint256 phase2 = requestedUnbonding - phase1;

        // `totalStaked` - `phase1`
        uint256 totalStakedAfterPhase1 = (totalPooled - batchDeposits) - phase1;

        uint256 n = _nodes.length;
        for (uint256 i; i < n; ++i) {
            // Phase 1: Unbond proportionally from over-allocated nodes only
            uint256 phase1Amount = overAllocations[i] > 0 ? phase1 * overAllocations[i] / overAllocation : 0;

            // Phase 2: Unbond remaining amount proportionally from all nodes based on remaining stake
            uint256 phase2Amount = phase2 > 0 ? phase2 * (_nodes[i].staked - phase1Amount) / totalStakedAfterPhase1 : 0;

            uint96 unbondAmount = uint96(phase1Amount + phase2Amount);

            if (unbondAmount > 0) {
                Registry.nodes[i].staked = _nodes[i].staked - unbondAmount;
                actualUnbonding += unbondAmount;
                Staker.undelegate(_nodes[i].id, unbondAmount);
            }
        }
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
            uint256 feeShares = (ERC20Upgradeable.totalSupply() + _managementFee.virtualSharesSnapshot) * _managementFee.bips / BIPS;
            uint256 feeSharesTimeWeighted = feeShares * time / YEAR;
            _managementFee.virtualSharesSnapshot = uint96(_managementFee.virtualSharesSnapshot + feeSharesTimeWeighted);
            _managementFee.lastUpdate = uint40(block.timestamp);
            managementFee = _managementFee;
        }
    }
}
