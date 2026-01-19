// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/src/Test.sol";
import {Splitter, SplitterFactory} from "../src/Splitter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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

contract SplitterTest is Test {
    Splitter public splitter;
    SplitterFactory public factory;
    
    MockTarget public target1;
    MockTarget public target2;
    MockTarget public target3;
    
    address public ADMIN = vm.addr(100);
    address public ALICE = vm.addr(101);
    address public BOB = vm.addr(102);
    address public CHARLIE = vm.addr(103);
    
    uint16 public constant BIPS = 10000;
    uint256 public constant MAX_SPLITS = 10;
    
    event SplitCreated(uint256 index, Splitter.Split split);
    event SplitUpdated(uint256 index, Splitter.Split oldSplit, Splitter.Split newSplit);
    event SplitDeleted(uint256 index, Splitter.Split oldSplit);
    event SplitApplied(uint256 index, address _target, bytes _calldata, uint256 _value);
    event SplitterCreated(address splitter);
    
    function setUp() public {
        vm.label(ADMIN, "//ADMIN");
        vm.label(ALICE, "//Alice");
        vm.label(BOB, "//Bob");
        vm.label(CHARLIE, "//Charlie");
        
        splitter = new Splitter(ADMIN);
        factory = new SplitterFactory();
        
        target1 = new MockTarget();
        target2 = new MockTarget();
        target3 = new MockTarget();
        
        vm.label(address(target1), "//Target1");
        vm.label(address(target2), "//Target2");
        vm.label(address(target3), "//Target3");
    }
    
    // ============================================
    // Constructor & Initialization Tests
    // ============================================
    
    function test_constructor_sets_admin_roles() public view {
        assertTrue(splitter.hasRole(splitter.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(splitter.hasRole(splitter.ROLE_SPLIT_CREATE(), ADMIN));
        assertTrue(splitter.hasRole(splitter.ROLE_SPLIT_UPDATE(), ADMIN));
        assertTrue(splitter.hasRole(splitter.ROLE_SPLIT_DELETE(), ADMIN));
    }

    function test_constructor_initializes_state() public view {
        assertEq(splitter.splitCount(), 0);
    }
    
    function test_receive_accepts_ether() public {
        uint256 amount = 10 ether;
        vm.deal(ALICE, amount);
        
        vm.startPrank(ALICE);
        (bool success,) = address(splitter).call{value: amount}("");
        assertTrue(success);
        assertEq(address(splitter).balance, amount);
    }
    
    // ============================================
    // Role Tests
    // ============================================
    
    function test_roles_can_be_granted_and_revoked() public {
        bytes32[] memory roles = new bytes32[](3);
        roles[0] = splitter.ROLE_SPLIT_CREATE();
        roles[1] = splitter.ROLE_SPLIT_UPDATE();
        roles[2] = splitter.ROLE_SPLIT_DELETE();
        
        vm.startPrank(ADMIN);
        for (uint256 i; i < roles.length; ++i) {
            bytes32 role = roles[i];
            
            // Grant role to Alice
            splitter.grantRole(role, ALICE);
            assertTrue(splitter.hasRole(role, ALICE), "Alice should have role");
            
            // Revoke role from Alice
            splitter.revokeRole(role, ALICE);
            assertFalse(splitter.hasRole(role, ALICE), "Alice should not have role");
        }
    }
    
    function test_non_admin_cannot_grant_roles() public {
        bytes32 role = splitter.ROLE_SPLIT_CREATE();
        
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            BOB,
            splitter.DEFAULT_ADMIN_ROLE()
        ));
        splitter.grantRole(role, ALICE);
    }
    
    // ============================================
    // Create Split Tests
    // ============================================
    
    function test_create_single_split() public {
        vm.startPrank(ADMIN);
        
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        vm.expectEmit(true, true, true, true);
        emit SplitCreated(0, splits[0]);
        
        splitter.updateSplits(indexes, splits);
        
        assertEq(splitter.splitCount(), 1);
        (uint16 bips, address target, bytes memory calldata_) = splitter.splits(0);
        assertEq(bips, BIPS);
        assertEq(target, address(target1));
        assertEq(calldata_, "");
    }
    
    function test_create_multiple_splits() public {
        vm.startPrank(ADMIN);
        
        uint256[] memory indexes = new uint256[](3);
        indexes[0] = 0;
        indexes[1] = 1;
        indexes[2] = 2;
        
        Splitter.Split[] memory splits = new Splitter.Split[](3);
        splits[0] = Splitter.Split({
            bips: 5000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 3000,
            _target: address(target2),
            _calldata: ""
        });
        splits[2] = Splitter.Split({
            bips: 2000,
            _target: address(target3),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        assertEq(splitter.splitCount(), 3);
        
        (uint16 bips1,,) = splitter.splits(0);
        assertEq(bips1, 5000);
        
        (uint16 bips2,,) = splitter.splits(1);
        assertEq(bips2, 3000);
        
        (uint16 bips3,,) = splitter.splits(2);
        assertEq(bips3, 2000);
    }
    
    function test_create_split_with_calldata() public {
        vm.startPrank(ADMIN);
        
        bytes memory calldata_ = abi.encodeWithSelector(MockTarget.mockFunction.selector, 123);
        
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: calldata_
        });
        
        splitter.updateSplits(indexes, splits);
        
        (,, bytes memory storedCalldata) = splitter.splits(0);
        assertEq(storedCalldata, calldata_);
    }
    
    function test_create_split_requires_role() public {
        vm.startPrank(BOB);
        
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            BOB,
            splitter.ROLE_SPLIT_CREATE()
        ));
        splitter.updateSplits(indexes, splits);
    }
    
    function test_create_split_reverts_invalid_index() public {
        vm.startPrank(ADMIN);
        
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = MAX_SPLITS; // Invalid index
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        vm.expectRevert("Invalid split index");
        splitter.updateSplits(indexes, splits);
    }
    
    function test_create_split_reverts_invalid_bips() public {
        vm.startPrank(ADMIN);
        
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS + 1, // Invalid bips
            _target: address(target1),
            _calldata: ""
        });
        
        vm.expectRevert("Invalid split bips");
        splitter.updateSplits(indexes, splits);
    }
    
    function test_create_split_reverts_mismatched_allocations() public {
        vm.startPrank(ADMIN);
        
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 5000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 4000, // Total = 9000, not 10000
            _target: address(target2),
            _calldata: ""
        });
        
        vm.expectRevert("Insufficient allocations");
        splitter.updateSplits(indexes, splits);
    }
    
    function test_create_split_reverts_excessive_allocations() public {
        vm.startPrank(ADMIN);
        
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 6000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 5000, // Total = 11000, not 10000
            _target: address(target2),
            _calldata: ""
        });
        
        vm.expectRevert("Insufficient allocations");
        splitter.updateSplits(indexes, splits);
    }
    
    function test_create_split_reverts_mismatched_arguments() public {
        vm.startPrank(ADMIN);
        
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1); // Mismatch
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        vm.expectRevert("Mismatched arguments");
        splitter.updateSplits(indexes, splits);
    }
    
    // ============================================
    // Update Split Tests
    // ============================================
    
    function test_update_existing_split() public {
        vm.startPrank(ADMIN);
        
        // Create initial split
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Update the split
        Splitter.Split memory oldSplit = splits[0];
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target2), // Changed target
            _calldata: abi.encodeWithSelector(MockTarget.mockFunction.selector, 456)
        });
        
        vm.expectEmit(true, true, true, true);
        emit SplitUpdated(0, oldSplit, splits[0]);
        
        splitter.updateSplits(indexes, splits);
        
        assertEq(splitter.splitCount(), 1); // Count unchanged
        (uint16 bips, address target, bytes memory calldata_) = splitter.splits(0);
        assertEq(bips, BIPS);
        assertEq(target, address(target2));
        assertEq(calldata_, abi.encodeWithSelector(MockTarget.mockFunction.selector, 456));
    }
    
    function test_update_split_requires_role() public {
        vm.startPrank(ADMIN);
        
        // Create initial split
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Try to update as BOB (no role)
        vm.startPrank(BOB);
        splits[0]._target = address(target2);
        
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            BOB,
            splitter.ROLE_SPLIT_UPDATE()
        ));
        splitter.updateSplits(indexes, splits);
    }
    
    function test_update_multiple_splits_at_once() public {
        vm.startPrank(ADMIN);
        
        // Create initial splits
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 6000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 4000,
            _target: address(target2),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Update both splits
        splits[0] = Splitter.Split({
            bips: 7000, // Changed bips
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 3000, // Changed bips
            _target: address(target2),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        (uint16 bips1,,) = splitter.splits(0);
        assertEq(bips1, 7000);
        
        (uint16 bips2,,) = splitter.splits(1);
        assertEq(bips2, 3000);
    }
    
    // ============================================
    // Delete Split Tests
    // ============================================
    
    function test_delete_split() public {
        vm.startPrank(ADMIN);
        
        // Create splits
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 50_00,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 50_00,
            _target: address(target2),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 2);
        
        // Delete split[0] by setting bips to 0
        Splitter.Split memory oldSplit0 = splits[0];
        oldSplit0.bips = 0;
        splits[0] = oldSplit0;
        Splitter.Split memory oldSplit1 = splits[1];
        oldSplit1.bips = BIPS;
        splits[1] = oldSplit1;
        
        splitter.updateSplits(indexes, splits);
        
        assertEq(splitter.splitCount(), 1);
        (uint16 bips,,) = splitter.splits(0);
        assertEq(bips, 0);
    }
    
    function test_delete_split_requires_role() public {
        vm.startPrank(ADMIN);
        
        // Create split
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Try to delete as BOB (no role)
        vm.startPrank(BOB);
        splits[0].bips = 0;
        
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            BOB,
            splitter.ROLE_SPLIT_DELETE()
        ));
        splitter.updateSplits(indexes, splits);
    }
    
    function test_delete_one_of_multiple_splits() public {
        vm.startPrank(ADMIN);
        
        // Create two splits
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 6000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 4000,
            _target: address(target2),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 2);
        
        // Delete first split and update second
        indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 0, // Delete
            _target: address(0),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: BIPS, // Now gets 100%
            _target: address(target2),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        assertEq(splitter.splitCount(), 1);
        (uint16 bips1,,) = splitter.splits(0);
        assertEq(bips1, 0);
        
        (uint16 bips2,,) = splitter.splits(1);
        assertEq(bips2, BIPS);
    }
    
    // ============================================
    // Withdraw Tests
    // ============================================
    
    function test_withdraw_single_split() public {
        vm.startPrank(ADMIN);
        
        // Create split
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Fund the splitter
        uint256 amount = 100 ether;
        vm.deal(address(splitter), amount);
        
        // Withdraw
        vm.expectEmit(true, true, true, true);
        emit SplitApplied(0, address(target1), "", amount);
        
        splitter.withdraw();
        
        assertEq(address(target1).balance, amount);
        assertEq(address(splitter).balance, 0);
    }
    
    function test_withdraw_multiple_splits() public {
        vm.startPrank(ADMIN);
        
        // Create splits
        uint256[] memory indexes = new uint256[](3);
        indexes[0] = 0;
        indexes[1] = 1;
        indexes[2] = 2;
        
        Splitter.Split[] memory splits = new Splitter.Split[](3);
        splits[0] = Splitter.Split({
            bips: 5000, // 50%
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 3000, // 30%
            _target: address(target2),
            _calldata: ""
        });
        splits[2] = Splitter.Split({
            bips: 2000, // 20%
            _target: address(target3),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Fund the splitter
        uint256 amount = 100 ether;
        vm.deal(address(splitter), amount);
        
        // Withdraw
        splitter.withdraw();
        
        assertEq(address(target1).balance, 50 ether);
        assertEq(address(target2).balance, 30 ether);
        assertEq(address(target3).balance, 20 ether);
        assertEq(address(splitter).balance, 0);
    }
    
    function test_withdraw_with_calldata() public {
        vm.startPrank(ADMIN);
        
        bytes memory calldata_ = abi.encodeWithSelector(MockTarget.mockFunction.selector, 789);
        
        // Create split with calldata
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: calldata_
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Fund the splitter
        uint256 amount = 10 ether;
        vm.deal(address(splitter), amount);
        
        // Withdraw
        splitter.withdraw();
        
        assertEq(address(target1).balance, amount);
        assertEq(target1.lastCallValue(), amount);
        assertEq(target1.lastCalldata(), calldata_);
    }
    
    function test_withdraw_skips_empty_splits() public {
        vm.startPrank(ADMIN);
        
        // Create splits at non-consecutive indices
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 5; // Skip indices 1-4
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 6000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 4000,
            _target: address(target2),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Fund the splitter
        uint256 amount = 100 ether;
        vm.deal(address(splitter), amount);
        
        // Withdraw (should skip indices 1-4)
        splitter.withdraw();
        
        assertEq(address(target1).balance, 60 ether);
        assertEq(address(target2).balance, 40 ether);
    }
    
    function test_withdraw_early_exit_optimization() public {
        vm.startPrank(ADMIN);
        
        // Create splits at indices 0 and 1 (should exit after index 1)
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 7000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 3000,
            _target: address(target2),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Fund the splitter
        uint256 amount = 100 ether;
        vm.deal(address(splitter), amount);
        
        // Withdraw (should exit early after finding all 2 splits)
        splitter.withdraw();
        
        assertEq(address(target1).balance, 70 ether);
        assertEq(address(target2).balance, 30 ether);
    }
    
    function test_withdraw_reverts_on_failed_call() public {
        vm.startPrank(ADMIN);
        
        // Setup target to revert
        target1.setRevert(true, "Target reverted");
        
        // Create split
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Fund the splitter
        vm.deal(address(splitter), 10 ether);
        
        // Withdraw should revert
        vm.expectRevert("Target reverted");
        splitter.withdraw();
    }
    
    function test_withdraw_reverts_on_failed_call_no_message() public {
        vm.startPrank(ADMIN);
        
        // Setup target to revert without message
        target1.setRevert(true, "");
        
        // Create split
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Fund the splitter
        vm.deal(address(splitter), 10 ether);
        
        // Withdraw should revert with generic message
        vm.expectRevert("Transaction execution reverted");
        splitter.withdraw();
    }
    
    function test_withdraw_with_zero_balance() public {
        vm.startPrank(ADMIN);
        
        // Create split
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Don't fund the splitter
        // Withdraw (should work but transfer 0)
        splitter.withdraw();
        
        assertEq(address(target1).balance, 0);
    }
    
    function test_withdraw_with_rounding() public {
        vm.startPrank(ADMIN);
        
        // Create splits with values that will cause rounding
        uint256[] memory indexes = new uint256[](3);
        indexes[0] = 0;
        indexes[1] = 1;
        indexes[2] = 2;
        
        Splitter.Split[] memory splits = new Splitter.Split[](3);
        splits[0] = Splitter.Split({
            bips: 3333, // 33.33%
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 3333, // 33.33%
            _target: address(target2),
            _calldata: ""
        });
        splits[2] = Splitter.Split({
            bips: 3334, // 33.34%
            _target: address(target3),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        
        // Fund with amount that doesn't divide evenly
        uint256 amount = 100 ether;
        vm.deal(address(splitter), amount);
        
        // Withdraw
        splitter.withdraw();
        
        // Check amounts (with rounding down)
        assertEq(address(target1).balance, (amount * 3333) / BIPS);
        assertEq(address(target2).balance, (amount * 3333) / BIPS);
        assertEq(address(target3).balance, (amount * 3334) / BIPS);
        
        // Some dust may remain due to rounding
        uint256 totalDistributed = address(target1).balance + address(target2).balance + address(target3).balance;
        assertLe(amount - totalDistributed, 2); // At most 2 wei dust
    }
    
    // ============================================
    // Complex Scenarios
    // ============================================
    
    function test_create_update_lifecycle() public {
        vm.startPrank(ADMIN);
        
        // 1. Create split
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        
        Splitter.Split[] memory splits = new Splitter.Split[](1);
        splits[0] = Splitter.Split({
            bips: BIPS,
            _target: address(target1),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 1);
        
        // 2. Update split
        splits[0]._target = address(target2);
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 1);
        
        (,address target,) = splitter.splits(0);
        assertEq(target, address(target2));
    }
    
    function test_can_use_all_10_split_slots() public {
        vm.startPrank(ADMIN);
        
        // Create 10 splits (max)
        uint256[] memory indexes = new uint256[](10);
        Splitter.Split[] memory splits = new Splitter.Split[](10);
        
        for (uint256 i = 0; i < 10; i++) {
            indexes[i] = i;
            splits[i] = Splitter.Split({
                bips: 1000, // 10% each
                _target: address(uint160(uint256(keccak256(abi.encode(i))))),
                _calldata: ""
            });
        }
        
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 10);
        
        // Verify all splits
        for (uint256 i = 0; i < 10; i++) {
            (uint16 bips,,) = splitter.splits(i);
            assertEq(bips, 1000);
        }
    }
    
    function test_atomic_batch_operations() public {
        vm.startPrank(ADMIN);
        
        // Atomically: create at index 0, create at index 5
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 5;
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({
            bips: 6000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 4000,
            _target: address(target2),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 2);
        
        // Atomically: update at index 0, delete at index 5, create at index 7
        indexes = new uint256[](3);
        indexes[0] = 0;
        indexes[1] = 5;
        indexes[2] = 7;
        
        splits = new Splitter.Split[](3);
        splits[0] = Splitter.Split({
            bips: 5000,
            _target: address(target1),
            _calldata: ""
        });
        splits[1] = Splitter.Split({
            bips: 0, // Delete
            _target: address(0),
            _calldata: ""
        });
        splits[2] = Splitter.Split({
            bips: 5000,
            _target: address(target3),
            _calldata: ""
        });
        
        splitter.updateSplits(indexes, splits);
        assertEq(splitter.splitCount(), 2);
        
        (uint16 bips0,,) = splitter.splits(0);
        assertEq(bips0, 5000);
        
        (uint16 bips5,,) = splitter.splits(5);
        assertEq(bips5, 0);
        
        (uint16 bips7,,) = splitter.splits(7);
        assertEq(bips7, 5000);
    }
    
    function test_fuzz_splits(uint16 a) public {
        vm.assume(a > 0 && a < BIPS);
        uint16 b = BIPS - a;
        
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
        
        Splitter.Split[] memory splits = new Splitter.Split[](2);
        splits[0] = Splitter.Split({bips: a, _target: address(target1), _calldata: ""});
        splits[1] = Splitter.Split({bips: b, _target: address(target2), _calldata: ""});

        vm.startPrank(ADMIN);

        splitter.updateSplits(indexes, splits);
        
        uint256 amount = 1000 ether;
        vm.deal(address(splitter), amount);
        
        splitter.withdraw();
        
        assertEq(address(target1).balance, (amount * a) / BIPS);
        assertEq(address(target2).balance, (amount * b) / BIPS);
    }
    
    // ============================================
    // SplitterFactory Tests
    // ============================================
    
    function test_factory_create() public {
        vm.expectEmit(false, false, false, false);
        emit SplitterCreated(address(0));

        address splitterAddress = factory.create(ALICE);
        
        Splitter newSplitter = Splitter(payable(splitterAddress));
        assertTrue(newSplitter.hasRole(newSplitter.DEFAULT_ADMIN_ROLE(), ALICE));
    }
}
