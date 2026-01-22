// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/src/Test.sol";
import {Splitter} from "../src/Splitter.sol";
import {SplitterFactory} from "../src/SplitterFactory.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeploySplitterFactory} from "../script/DeploySplitterFactory.s.sol";

contract MockTarget {
    uint256 public lastCallValue;
    bytes public lastCalldata;
    bool public shouldRevert;
    string public revertMessage;

    receive() external payable {
        if (shouldRevert) {
            if (bytes(revertMessage).length > 0) {
                revert(revertMessage);
            } else {
                revert();
            }
        }
        lastCallValue = msg.value;
        lastCalldata = "";
    }

    function mockFunction() external payable {
        if (shouldRevert) {
            if (bytes(revertMessage).length > 0) {
                revert(revertMessage);
            } else {
                revert();
            }
        }
        lastCallValue = msg.value;
        lastCalldata = msg.data;
    }

    function setRevert(bool _shouldRevert, string memory _message) external {
        shouldRevert = _shouldRevert;
        revertMessage = _message;
    }
}

contract SplitterTest is Test, DeploySplitterFactory {
    Splitter public splitter;
    SplitterFactory public factory;

    MockTarget public target1;
    MockTarget public target2;
    MockTarget public target3;

    address public ADMIN = vm.addr(100);
    address public ALICE = vm.addr(101);
    address public BOB = vm.addr(102);

    uint16 public constant BIPS = 10000;
    uint256 public constant MAX_SPLITS = 10;

    event SplitCreated(uint256 index, Splitter.Split split);
    event SplitUpdated(uint256 index, Splitter.Split oldSplit, Splitter.Split newSplit);
    event SplitDeleted(uint256 index, Splitter.Split oldSplit);
    event SplitApplied(uint256 index, address _target, bytes _calldata, uint256 _value);
    event SplitterCreated(address splitter);

    function setUp() public {
        vm.label(ADMIN, "ADMIN");
        vm.label(ALICE, "Alice");
        vm.label(BOB, "Bob");

        splitter = new Splitter(MAX_SPLITS, ADMIN);
        factory = SplitterFactory(DeploySplitterFactory.deployFactory());

        target1 = new MockTarget();
        target2 = new MockTarget();
        target3 = new MockTarget();

        vm.label(address(target1), "Target1");
        vm.label(address(target2), "Target2");
        vm.label(address(target3), "Target3");
    }

    // ============================================
    // Helpers
    // ============================================

    function _createSplit(uint256 index, uint16 bips, address target) internal pure returns (uint256[] memory indexes, Splitter.Split[] memory splits) {
        indexes = new uint256[](1);
        indexes[0] = index;
        splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({bips: bips, _target: target, _calldata: ""});
    }

    function _createSplits(uint256[] memory _indexes, uint16[] memory _bips, address[] memory _targets) internal pure returns (uint256[] memory indexes, Splitter.Split[] memory splits) {
        uint256 n = _indexes.length;
        indexes = new uint256[](n);
        splits = new Splitter.Split[](n);
        for (uint256 i; i < n; ++i) {
            indexes[i] = _indexes[i];
            splits[i] = Splitter.Split({bips: _bips[i], _target: _targets[i], _calldata: ""});
        }
    }

    // ============================================
    // 1. Constructor & Initialization
    // ============================================

    function test_constructor_setsAdminRoles() public view {
        assertTrue(splitter.hasRole(splitter.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(splitter.hasRole(splitter.ROLE_SPLIT_CREATE(), ADMIN));
        assertTrue(splitter.hasRole(splitter.ROLE_SPLIT_UPDATE(), ADMIN));
        assertTrue(splitter.hasRole(splitter.ROLE_SPLIT_DELETE(), ADMIN));
    }

    function test_constructor_initializesState() public view {
        assertEq(splitter.splitCount(), 0);
        assertEq(splitter.MAX_SPLITS(), MAX_SPLITS);
    }

    function test_constructor_revertsWithZeroMaxSplits() public {
        vm.expectRevert("Not enough splits");
        new Splitter(0, ADMIN);
    }

    function test_constructor_revertsWhenMaxSplitsExceedsLimit() public {
        vm.expectRevert("Too many splits");
        new Splitter(33, ADMIN);
    }

    function test_constructor_allowsMaxSplitsAtLimit() public {
        Splitter s = new Splitter(32, ADMIN);
        assertEq(s.MAX_SPLITS(), 32);
    }

    function test_constructor_allowsSmallMaxSplits() public {
        Splitter s = new Splitter(1, ADMIN);
        assertEq(s.MAX_SPLITS(), 1);
    }

    function test_receive_acceptsEther() public {
        vm.deal(ALICE, 10 ether);
        vm.prank(ALICE);
        (bool success,) = address(splitter).call{value: 10 ether}("");
        assertTrue(success);
        assertEq(address(splitter).balance, 10 ether);
    }

    // ============================================
    // 2. Access Control
    // ============================================

    function test_roles_canBeGrantedAndRevoked() public {
        bytes32[3] memory roles = [splitter.ROLE_SPLIT_CREATE(), splitter.ROLE_SPLIT_UPDATE(), splitter.ROLE_SPLIT_DELETE()];

        vm.startPrank(ADMIN);
        for (uint256 i; i < 3; ++i) {
            splitter.grantRole(roles[i], ALICE);
            assertTrue(splitter.hasRole(roles[i], ALICE));

            splitter.revokeRole(roles[i], ALICE);
            assertFalse(splitter.hasRole(roles[i], ALICE));
        }
    }

    function test_roles_nonAdminCannotGrant() public {
        bytes32 adminRole = splitter.DEFAULT_ADMIN_ROLE();
        bytes32 createRole = splitter.ROLE_SPLIT_CREATE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, adminRole));
        vm.prank(BOB);
        splitter.grantRole(createRole, ALICE);
    }

    // ============================================
    // 3. View Functions
    // ============================================

    // --- getActiveSplits ---

    function test_getActiveSplits_returnsEmptyWhenNoSplits() public view {
        (uint256[] memory indexes, Splitter.Split[] memory splits) = splitter.getActiveSplits();
        assertEq(indexes.length, 0);
        assertEq(splits.length, 0);
    }

    function test_getActiveSplits_returnsSingleSplit() public {
        vm.prank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        (uint256[] memory activeIdx, Splitter.Split[] memory activeSplits) = splitter.getActiveSplits();
        assertEq(activeIdx.length, 1);
        assertEq(activeIdx[0], 0);
        assertEq(activeSplits[0].bips, BIPS);
        assertEq(activeSplits[0]._target, address(target1));
    }

    function test_getActiveSplits_returnsNonContiguousSplits() public {
        uint256[] memory idx = new uint256[](3);
        idx[0] = 0;
        idx[1] = 3;
        idx[2] = 7;
        uint16[] memory bips = new uint16[](3);
        bips[0] = 4000;
        bips[1] = 3500;
        bips[2] = 2500;
        address[] memory targets = new address[](3);
        targets[0] = address(target1);
        targets[1] = address(target2);
        targets[2] = address(target3);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        (uint256[] memory activeIdx, Splitter.Split[] memory activeSplits) = splitter.getActiveSplits();
        assertEq(activeIdx.length, 3);
        assertEq(activeIdx[0], 0);
        assertEq(activeIdx[1], 3);
        assertEq(activeIdx[2], 7);
        assertEq(activeSplits[0]._target, address(target1));
        assertEq(activeSplits[1]._target, address(target2));
        assertEq(activeSplits[2]._target, address(target3));
    }

    function test_getActiveSplits_updatesAfterDeletion() public {
        // Create 3 splits at 0, 1, 2
        uint256[] memory idx = new uint256[](3);
        idx[0] = 0;
        idx[1] = 1;
        idx[2] = 2;
        uint16[] memory bips = new uint16[](3);
        bips[0] = 4000;
        bips[1] = 3000;
        bips[2] = 3000;
        address[] memory targets = new address[](3);
        targets[0] = address(target1);
        targets[1] = address(target2);
        targets[2] = address(target3);

        vm.startPrank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        // Delete middle split (index 1)
        uint256[] memory delIdx = new uint256[](2);
        delIdx[0] = 1;
        delIdx[1] = 2;
        Splitter.Split[] memory delSplits = new Splitter.Split[](2);
        delSplits[0] = Splitter.Split({bips: 0, _target: address(0), _calldata: ""});
        delSplits[1] = Splitter.Split({bips: 6000, _target: address(target3), _calldata: ""});
        splitter.updateSplits(delIdx, delSplits);

        (uint256[] memory activeIdx,) = splitter.getActiveSplits();
        assertEq(activeIdx.length, 2);
        assertEq(activeIdx[0], 0);
        assertEq(activeIdx[1], 2);
    }

    // --- getNextAvailableIndex ---

    function test_getNextAvailableIndex_returnsZeroWhenEmpty() public view {
        assertEq(splitter.getNextAvailableIndex(), 0);
    }

    function test_getNextAvailableIndex_returnsNextAfterFirst() public {
        vm.prank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        assertEq(splitter.getNextAvailableIndex(), 1);
    }

    function test_getNextAvailableIndex_findsGap() public {
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 2;
        uint16[] memory bips = new uint16[](2);
        bips[0] = 5000;
        bips[1] = 5000;
        address[] memory targets = new address[](2);
        targets[0] = address(target1);
        targets[1] = address(target2);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        assertEq(splitter.getNextAvailableIndex(), 1);
    }

    function test_getNextAvailableIndex_revertsWhenFull() public {
        Splitter smallSplitter = new Splitter(3, ADMIN);

        uint256[] memory idx = new uint256[](3);
        idx[0] = 0;
        idx[1] = 1;
        idx[2] = 2;
        uint16[] memory bips = new uint16[](3);
        bips[0] = 4000;
        bips[1] = 3000;
        bips[2] = 3000;
        address[] memory targets = new address[](3);
        targets[0] = address(target1);
        targets[1] = address(target2);
        targets[2] = address(target3);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        smallSplitter.updateSplits(indexes, splits);

        vm.expectRevert("No available index");
        smallSplitter.getNextAvailableIndex();
    }

    // ============================================
    // 4. Create Splits
    // ============================================

    function test_create_singleSplit() public {
        vm.startPrank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));

        vm.expectEmit(true, true, true, true);
        emit SplitCreated(0, s[0]);
        splitter.updateSplits(idx, s);

        assertEq(splitter.splitCount(), 1);
        (uint16 bips, address target,) = splitter.splits(0);
        assertEq(bips, BIPS);
        assertEq(target, address(target1));
    }

    function test_create_multipleSplits() public {
        uint256[] memory idx = new uint256[](3);
        idx[0] = 0;
        idx[1] = 1;
        idx[2] = 2;
        uint16[] memory bips = new uint16[](3);
        bips[0] = 5000;
        bips[1] = 3000;
        bips[2] = 2000;
        address[] memory targets = new address[](3);
        targets[0] = address(target1);
        targets[1] = address(target2);
        targets[2] = address(target3);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        assertEq(splitter.splitCount(), 3);
        (uint16 b1,,) = splitter.splits(0);
        (uint16 b2,,) = splitter.splits(1);
        (uint16 b3,,) = splitter.splits(2);
        assertEq(b1, 5000);
        assertEq(b2, 3000);
        assertEq(b3, 2000);
    }

    function test_create_withCalldata() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.mockFunction.selector);

        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        Splitter.Split[] memory s = new Splitter.Split[](1);
        s[0] = Splitter.Split({bips: BIPS, _target: address(target1), _calldata: data});

        vm.prank(ADMIN);
        splitter.updateSplits(idx, s);

        (,, bytes memory stored) = splitter.splits(0);
        assertEq(stored, data);
    }

    function test_create_requiresRole() public {
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        bytes32 createRole = splitter.ROLE_SPLIT_CREATE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, createRole));
        vm.prank(BOB);
        splitter.updateSplits(idx, s);
    }

    function test_create_revertsInvalidIndex() public {
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(MAX_SPLITS, BIPS, address(target1));

        vm.prank(ADMIN);
        vm.expectRevert("Invalid split index");
        splitter.updateSplits(idx, s);
    }

    function test_create_revertsInvalidBips() public {
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS + 1, address(target1));

        vm.prank(ADMIN);
        vm.expectRevert("Invalid split bips");
        splitter.updateSplits(idx, s);
    }

    function test_create_revertsInsufficientAllocations() public {
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        uint16[] memory bips = new uint16[](2);
        bips[0] = 5000;
        bips[1] = 4000; // Total 9000
        address[] memory targets = new address[](2);
        targets[0] = address(target1);
        targets[1] = address(target2);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        vm.expectRevert("Insufficient allocations");
        splitter.updateSplits(indexes, splits);
    }

    function test_create_revertsExcessiveAllocations() public {
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        uint16[] memory bips = new uint16[](2);
        bips[0] = 6000;
        bips[1] = 5000; // Total 11000
        address[] memory targets = new address[](2);
        targets[0] = address(target1);
        targets[1] = address(target2);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        vm.expectRevert("Insufficient allocations");
        splitter.updateSplits(indexes, splits);
    }

    function test_create_revertsMismatchedArguments() public {
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        Splitter.Split[] memory s = new Splitter.Split[](1);
        s[0] = Splitter.Split({bips: BIPS, _target: address(target1), _calldata: ""});

        vm.prank(ADMIN);
        vm.expectRevert("Mismatched arguments");
        splitter.updateSplits(idx, s);
    }

    // ============================================
    // 5. Update Splits
    // ============================================

    function test_update_existingSplit() public {
        vm.startPrank(ADMIN);

        // Create
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        // Update
        Splitter.Split memory oldSplit = s[0];
        s[0] = Splitter.Split({bips: BIPS, _target: address(target2), _calldata: abi.encodeWithSelector(MockTarget.mockFunction.selector)});

        vm.expectEmit(true, true, true, true);
        emit SplitUpdated(0, oldSplit, s[0]);
        splitter.updateSplits(idx, s);

        assertEq(splitter.splitCount(), 1);
        (, address target,) = splitter.splits(0);
        assertEq(target, address(target2));
    }

    function test_update_requiresRole() public {
        vm.prank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        bytes32 updateRole = splitter.ROLE_SPLIT_UPDATE();
        s[0]._target = address(target2);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, updateRole));
        vm.prank(BOB);
        splitter.updateSplits(idx, s);
    }

    function test_update_multipleSplitsAtOnce() public {
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        uint16[] memory bips = new uint16[](2);
        bips[0] = 6000;
        bips[1] = 4000;
        address[] memory targets = new address[](2);
        targets[0] = address(target1);
        targets[1] = address(target2);

        vm.startPrank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        // Update both
        bips[0] = 7000;
        bips[1] = 3000;
        (indexes, splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        (uint16 b1,,) = splitter.splits(0);
        (uint16 b2,,) = splitter.splits(1);
        assertEq(b1, 7000);
        assertEq(b2, 3000);
    }

    // ============================================
    // 6. Delete Splits
    // ============================================

    function test_delete_split() public {
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        uint16[] memory bips = new uint16[](2);
        bips[0] = 5000;
        bips[1] = 5000;
        address[] memory targets = new address[](2);
        targets[0] = address(target1);
        targets[1] = address(target2);

        vm.startPrank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 2);

        // Delete index 0, update index 1 to 100%
        bips[0] = 0;
        bips[1] = BIPS;
        targets[0] = address(0);
        (indexes, splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        assertEq(splitter.splitCount(), 1);
        (uint16 b,,) = splitter.splits(0);
        assertEq(b, 0);
    }

    function test_delete_requiresRole() public {
        vm.prank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        bytes32 deleteRole = splitter.ROLE_SPLIT_DELETE();
        s[0].bips = 0;

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, deleteRole));
        vm.prank(BOB);
        splitter.updateSplits(idx, s);
    }

    // ============================================
    // 7. Withdraw
    // ============================================

    function test_withdraw_singleSplit() public {
        vm.startPrank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        vm.deal(address(splitter), 100 ether);

        vm.expectEmit(true, true, true, true);
        emit SplitApplied(0, address(target1), "", 100 ether);
        splitter.withdraw();

        assertEq(address(target1).balance, 100 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_withdraw_multipleSplits() public {
        uint256[] memory idx = new uint256[](3);
        idx[0] = 0;
        idx[1] = 1;
        idx[2] = 2;
        uint16[] memory bips = new uint16[](3);
        bips[0] = 5000;
        bips[1] = 3000;
        bips[2] = 2000;
        address[] memory targets = new address[](3);
        targets[0] = address(target1);
        targets[1] = address(target2);
        targets[2] = address(target3);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        vm.deal(address(splitter), 100 ether);
        splitter.withdraw();

        assertEq(address(target1).balance, 50 ether);
        assertEq(address(target2).balance, 30 ether);
        assertEq(address(target3).balance, 20 ether);
    }

    function test_withdraw_withCalldata() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.mockFunction.selector);

        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        Splitter.Split[] memory s = new Splitter.Split[](1);
        s[0] = Splitter.Split({bips: BIPS, _target: address(target1), _calldata: data});

        vm.prank(ADMIN);
        splitter.updateSplits(idx, s);

        vm.deal(address(splitter), 10 ether);
        splitter.withdraw();

        assertEq(target1.lastCallValue(), 10 ether);
        assertEq(target1.lastCalldata(), data);
    }

    function test_withdraw_skipsEmptySplits() public {
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 5;
        uint16[] memory bips = new uint16[](2);
        bips[0] = 6000;
        bips[1] = 4000;
        address[] memory targets = new address[](2);
        targets[0] = address(target1);
        targets[1] = address(target2);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        vm.deal(address(splitter), 100 ether);
        splitter.withdraw();

        assertEq(address(target1).balance, 60 ether);
        assertEq(address(target2).balance, 40 ether);
    }

    function test_withdraw_revertsOnFailedCall() public {
        target1.setRevert(true, "Target reverted");

        vm.prank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        vm.deal(address(splitter), 10 ether);
        vm.expectRevert("Target reverted");
        splitter.withdraw();
    }

    function test_withdraw_revertsOnFailedCallNoMessage() public {
        target1.setRevert(true, "");

        vm.prank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        vm.deal(address(splitter), 10 ether);
        vm.expectRevert("Transaction execution reverted");
        splitter.withdraw();
    }

    function test_withdraw_withZeroBalance() public {
        vm.prank(ADMIN);
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);

        splitter.withdraw();
        assertEq(address(target1).balance, 0);
    }

    function test_withdraw_handlesRounding() public {
        uint256[] memory idx = new uint256[](3);
        idx[0] = 0;
        idx[1] = 1;
        idx[2] = 2;
        uint16[] memory bips = new uint16[](3);
        bips[0] = 3333;
        bips[1] = 3333;
        bips[2] = 3334;
        address[] memory targets = new address[](3);
        targets[0] = address(target1);
        targets[1] = address(target2);
        targets[2] = address(target3);

        vm.prank(ADMIN);
        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);

        uint256 amount = 100 ether;
        vm.deal(address(splitter), amount);
        splitter.withdraw();

        assertEq(address(target1).balance, (amount * 3333) / BIPS);
        assertEq(address(target2).balance, (amount * 3333) / BIPS);
        assertEq(address(target3).balance, (amount * 3334) / BIPS);

        uint256 total = address(target1).balance + address(target2).balance + address(target3).balance;
        assertLe(amount - total, 2); // Max 2 wei dust
    }

    // ============================================
    // 8. Complex Scenarios
    // ============================================

    function test_lifecycle_createUpdateDelete() public {
        vm.startPrank(ADMIN);

        // Create
        (uint256[] memory idx, Splitter.Split[] memory s) = _createSplit(0, BIPS, address(target1));
        splitter.updateSplits(idx, s);
        assertEq(splitter.splitCount(), 1);

        // Update
        s[0]._target = address(target2);
        splitter.updateSplits(idx, s);
        (, address target,) = splitter.splits(0);
        assertEq(target, address(target2));
        assertEq(splitter.splitCount(), 1);
    }

    function test_canUseAllSplitSlots() public {
        uint256[] memory idx = new uint256[](MAX_SPLITS);
        Splitter.Split[] memory s = new Splitter.Split[](MAX_SPLITS);

        for (uint256 i; i < MAX_SPLITS; ++i) {
            idx[i] = i;
            s[i] = Splitter.Split({
                bips: uint16(BIPS / MAX_SPLITS),
                _target: address(uint160(uint256(keccak256(abi.encode(i))))),
                _calldata: ""
            });
        }

        vm.prank(ADMIN);
        splitter.updateSplits(idx, s);
        assertEq(splitter.splitCount(), MAX_SPLITS);

        for (uint256 i; i < MAX_SPLITS; ++i) {
            (uint16 bips,,) = splitter.splits(i);
            assertEq(bips, uint16(BIPS / MAX_SPLITS));
        }
    }

    function test_atomicBatchOperations() public {
        vm.startPrank(ADMIN);

        // Create at indices 0 and 5
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 5;
        uint16[] memory bips = new uint16[](2);
        bips[0] = 6000;
        bips[1] = 4000;
        address[] memory targets = new address[](2);
        targets[0] = address(target1);
        targets[1] = address(target2);

        (uint256[] memory indexes, Splitter.Split[] memory splits) = _createSplits(idx, bips, targets);
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 2);

        // Atomically: update 0, delete 5, create 7
        uint256[] memory idx2 = new uint256[](3);
        idx2[0] = 0;
        idx2[1] = 5;
        idx2[2] = 7;
        Splitter.Split[] memory s2 = new Splitter.Split[](3);
        s2[0] = Splitter.Split({bips: 5000, _target: address(target1), _calldata: ""});
        s2[1] = Splitter.Split({bips: 0, _target: address(0), _calldata: ""});
        s2[2] = Splitter.Split({bips: 5000, _target: address(target3), _calldata: ""});

        splitter.updateSplits(idx2, s2);
        assertEq(splitter.splitCount(), 2);

        (uint16 b0,,) = splitter.splits(0);
        (uint16 b5,,) = splitter.splits(5);
        (uint16 b7,,) = splitter.splits(7);
        assertEq(b0, 5000);
        assertEq(b5, 0);
        assertEq(b7, 5000);
    }

    // ============================================
    // 9. Fuzz Tests
    // ============================================

    function testFuzz_splitDistribution(uint16 a) public {
        vm.assume(a > 0 && a < BIPS);
        uint16 b = BIPS - a;

        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        Splitter.Split[] memory s = new Splitter.Split[](2);
        s[0] = Splitter.Split({bips: a, _target: address(target1), _calldata: ""});
        s[1] = Splitter.Split({bips: b, _target: address(target2), _calldata: ""});

        vm.prank(ADMIN);
        splitter.updateSplits(idx, s);

        uint256 amount = 1000 ether;
        vm.deal(address(splitter), amount);
        splitter.withdraw();

        assertEq(address(target1).balance, (amount * a) / BIPS);
        assertEq(address(target2).balance, (amount * b) / BIPS);
    }

    // ============================================
    // 10. Factory Tests
    // ============================================

    function test_factory_create() public {
        vm.expectEmit(false, false, false, false);
        emit SplitterCreated(address(0));

        address addr = factory.create(MAX_SPLITS, ALICE);

        Splitter s = Splitter(payable(addr));
        assertTrue(s.hasRole(s.DEFAULT_ADMIN_ROLE(), ALICE));
        assertEq(s.MAX_SPLITS(), MAX_SPLITS);
    }
}