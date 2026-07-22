// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SYTestBase} from "./SYTestBase.sol";
import {PendleWsgemSY} from "../src/PendleWsgemSY.sol";
import {MaseerPrice} from "maseer-one/MaseerPrice.sol";
import {MaseerOne as Wsgem} from "maseer-one/MaseerOne.sol";
import {MockGem} from "./mocks/MockGem.sol";

/// @notice Random deposits (both tokens), redeems, and oracle pokes; the SY must stay
/// exactly 1:1 backed by wsgem at all times.
contract SYHandler is Test {
    PendleWsgemSY internal sy;
    Wsgem internal wsgem;
    MockGem internal gem;
    MaseerPrice internal pip;

    address[3] internal users;

    constructor(PendleWsgemSY sy_, Wsgem wsgem_, MockGem gem_, MaseerPrice pip_) {
        sy = sy_;
        wsgem = wsgem_;
        gem = gem_;
        pip = pip_;
        users = [makeAddr("u1"), makeAddr("u2"), makeAddr("u3")];
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function depositGem(uint256 seed, uint256 amt) external {
        address usr = _user(seed);
        amt = bound(amt, wsgem.mintcost(), 1e27);
        gem.mint(usr, amt);
        vm.startPrank(usr);
        gem.approve(address(sy), amt);
        sy.deposit(usr, address(gem), amt, 0);
        vm.stopPrank();
    }

    function depositWsgem(uint256 seed, uint256 amt) external {
        address usr = _user(seed);
        amt = bound(amt, 1, 1e27);
        uint256 cost = (amt * wsgem.mintcost()) / 1e18 + wsgem.mintcost();
        gem.mint(usr, cost);
        vm.startPrank(usr);
        gem.approve(address(wsgem), cost);
        uint256 got = wsgem.mint(cost);
        if (got >= amt) {
            wsgem.approve(address(sy), amt);
            sy.deposit(usr, address(wsgem), amt, 0);
        }
        vm.stopPrank();
    }

    function redeem(uint256 seed, uint256 amt) external {
        address usr = _user(seed);
        uint256 bal = sy.balanceOf(usr);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(usr);
        sy.redeem(usr, amt, address(wsgem), 0, false);
    }

    function poke(uint256 price) external {
        price = bound(price, 0.5e18, 5e18);
        pip.poke(price);
    }
}

contract PendleWsgemSYInvariantTest is SYTestBase {
    SYHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SYHandler(sy, wsgem, gem, pip);
        // The oracle only accepts pokes from kissed addresses; without this the
        // handler's poke() calls all revert silently (fail_on_revert = false) and
        // oracle movement is never exercised.
        pip.kiss(address(handler));
        targetContract(address(handler));
    }

    function invariant_SharesFullyBackedByWsgem() public view {
        assertEq(wsgem.balanceOf(address(sy)), sy.totalSupply());
    }

    function invariant_ExchangeRateEqualsNavprice() public view {
        assertEq(sy.exchangeRate(), wsgem.navprice());
    }

    function invariant_NoStrandedGem() public view {
        assertEq(gem.balanceOf(address(sy)), 0);
    }
}
