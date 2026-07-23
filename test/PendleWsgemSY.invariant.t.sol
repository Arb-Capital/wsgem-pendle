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
///
/// Ghost success counters make vacuous passes detectable: `fail_on_revert = false`
/// silently swallows reverting handler calls, so a setUp regression (like the pip.kiss
/// omission this suite once had) would otherwise reduce every invariant to `0 == 0`.
/// The deterministic test_HandlerWiring_* test proves every op can succeed.
contract SYHandler is Test {
    PendleWsgemSY internal sy;
    Wsgem internal wsgem;
    MockGem internal gem;
    MaseerPrice internal pip;

    address[3] internal users;

    uint256 public depositGemOk;
    uint256 public depositWsgemOk;
    uint256 public redeemOk;
    uint256 public pokeOk;
    // Last successfully poked price: lets the exchange-rate invariant compare the SY
    // against the handler's own record instead of re-reading navprice() (which would
    // be a tautology — exchangeRate() literally returns navprice()).
    uint256 public ghostNavprice;

    constructor(PendleWsgemSY sy_, Wsgem wsgem_, MockGem gem_, MaseerPrice pip_) {
        sy = sy_;
        wsgem = wsgem_;
        gem = gem_;
        pip = pip_;
        users = [makeAddr("u1"), makeAddr("u2"), makeAddr("u3")];
        ghostNavprice = wsgem.navprice();
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
        depositGemOk++;
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
            depositWsgemOk++;
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
        redeemOk++;
    }

    function poke(uint256 price) external {
        price = bound(price, 0.5e18, 5e18);
        pip.poke(price);
        pokeOk++;
        ghostNavprice = price;
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

    function invariant_ExchangeRateTracksOracle() public view {
        assertEq(sy.exchangeRate(), handler.ghostNavprice());
    }

    function invariant_NoStrandedGem() public view {
        assertEq(gem.balanceOf(address(sy)), 0);
    }

    /// @dev Deterministic wiring proof: every handler op must succeed when driven
    /// directly from the campaign's starting state. `fail_on_revert = false` silently
    /// swallows reverting handler calls during the campaign, so a setUp regression
    /// (like the pip.kiss omission this suite once had) would otherwise reduce every
    /// invariant to a vacuous `0 == 0` pass.
    function test_HandlerWiring_AllOpsSucceed() public {
        handler.depositGem(0, 5e18);
        handler.depositWsgem(1, 2e18);
        handler.redeem(0, 1e18);
        handler.poke(1e18);
        assertEq(handler.depositGemOk(), 1);
        assertEq(handler.depositWsgemOk(), 1);
        assertEq(handler.redeemOk(), 1);
        assertEq(handler.pokeOk(), 1);
        assertEq(sy.exchangeRate(), 1e18);
    }
}

/// @notice Adversarial regime: the issuer randomly smelts the SY's backing and healers
/// randomly remediate, interleaved with deposits/redeems/pokes. Handlers are written
/// total — during a deficit they attempt the operation anyway and record whether the
/// SY enforced its fail-closed rules — so misbehavior surfaces as a non-zero violation
/// counter in an invariant, never as a silently-swallowed revert.
contract SYAdversarialHandler is Test {
    PendleWsgemSY internal sy;
    Wsgem internal wsgem;
    MockGem internal gem;
    MaseerPrice internal pip;
    address internal issuer;

    address[3] internal users;

    uint256 public ghostSmelted; // cumulative wsgem burned from the SY
    uint256 public ghostHealed; // cumulative wsgem donated back to the SY

    uint256 public depositOk;
    uint256 public depositBlockedOk; // deposits correctly refused while in deficit
    uint256 public redeemOk;
    uint256 public redeemTailBlockedOk; // over-balance redeems correctly refused
    uint256 public smeltOk;
    uint256 public healOk;
    uint256 public pokeOk;

    // Violation counters — every one of these staying zero IS the invariant.
    uint256 public depositAcceptedInDeficit;
    uint256 public depositWrongError;
    uint256 public redeemOverdrawn;
    uint256 public redeemWrongError;

    constructor(PendleWsgemSY sy_, Wsgem wsgem_, MockGem gem_, MaseerPrice pip_, address issuer_) {
        sy = sy_;
        wsgem = wsgem_;
        gem = gem_;
        pip = pip_;
        issuer = issuer_;
        users = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function _insolvent(uint256 shortfall) internal pure returns (bytes32) {
        return keccak256(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, shortfall));
    }

    function depositWsgem(uint256 seed, uint256 amt) external {
        address usr = _user(seed);
        amt = bound(amt, 1, 1e24);
        uint256 cost = (amt * wsgem.mintcost()) / 1e18 + wsgem.mintcost();
        gem.mint(usr, cost);
        vm.startPrank(usr);
        gem.approve(address(wsgem), cost);
        uint256 got = wsgem.mint(cost);
        if (got < amt) {
            vm.stopPrank();
            return;
        }
        wsgem.approve(address(sy), amt);
        uint256 shortfall = sy.deficit();
        if (shortfall == 0) {
            sy.deposit(usr, address(wsgem), amt, 0);
            depositOk++;
        } else {
            // Both deposit routes must fail closed with the pre-deposit deficit.
            try sy.deposit(usr, address(wsgem), amt, 0) returns (uint256) {
                depositAcceptedInDeficit++;
            } catch (bytes memory err) {
                if (keccak256(err) == _insolvent(shortfall)) depositBlockedOk++;
                else depositWrongError++;
            }
        }
        vm.stopPrank();
    }

    function depositGem(uint256 seed, uint256 amt) external {
        address usr = _user(seed);
        amt = bound(amt, wsgem.mintcost(), 1e24);
        gem.mint(usr, amt);
        vm.startPrank(usr);
        gem.approve(address(sy), amt);
        uint256 shortfall = sy.deficit();
        if (shortfall == 0) {
            sy.deposit(usr, address(gem), amt, 0);
            depositOk++;
        } else {
            try sy.deposit(usr, address(gem), amt, 0) returns (uint256) {
                depositAcceptedInDeficit++;
            } catch (bytes memory err) {
                if (keccak256(err) == _insolvent(shortfall)) depositBlockedOk++;
                else depositWrongError++;
            }
        }
        vm.stopPrank();
    }

    function redeem(uint256 seed, uint256 amt) external {
        address usr = _user(seed);
        uint256 shares = sy.balanceOf(usr);
        if (shares == 0) return;
        amt = bound(amt, 1, shares);
        uint256 bal = wsgem.balanceOf(address(sy));
        vm.prank(usr);
        if (amt <= bal) {
            sy.redeem(usr, amt, address(wsgem), 0, false);
            redeemOk++;
        } else {
            // First-come redemption: the unbacked tail must revert SYInsolvent with
            // the exact shortfall (execution parity with previewRedeem).
            try sy.redeem(usr, amt, address(wsgem), 0, false) returns (uint256) {
                redeemOverdrawn++;
            } catch (bytes memory err) {
                if (keccak256(err) == _insolvent(amt - bal)) redeemTailBlockedOk++;
                else redeemWrongError++;
            }
        }
    }

    function smelt(uint256 amt) external {
        uint256 bal = wsgem.balanceOf(address(sy));
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(issuer);
        wsgem.smelt(address(sy), amt);
        ghostSmelted += amt;
        smeltOk++;
    }

    function heal(uint256 amt) external {
        uint256 shortfall = sy.deficit();
        if (shortfall == 0) return;
        amt = bound(amt, 1, shortfall);
        address healer = users[0];
        uint256 cost = (amt * wsgem.mintcost()) / 1e18 + wsgem.mintcost();
        gem.mint(healer, cost);
        vm.startPrank(healer);
        gem.approve(address(wsgem), cost);
        uint256 got = wsgem.mint(cost);
        if (got < amt) {
            vm.stopPrank();
            return;
        }
        wsgem.transfer(address(sy), amt);
        vm.stopPrank();
        ghostHealed += amt;
        healOk++;
    }

    function poke(uint256 price) external {
        price = bound(price, 0.5e18, 5e18);
        pip.poke(price);
        pokeOk++;
    }
}

contract PendleWsgemSYAdversarialInvariantTest is SYTestBase {
    SYAdversarialHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SYAdversarialHandler(sy, wsgem, gem, pip, issuer);
        pip.kiss(address(handler));
        targetContract(address(handler));
    }

    /// @dev Exact conservation across the whole lifecycle: every share was matched by
    /// wsgem on the way in and out, so the only ways balance and supply diverge are
    /// privileged smelts (tracked) and donations (tracked). Catches any path that
    /// mints shares without backing or leaks backing without burning shares.
    function invariant_BackingConservation() public view {
        assertEq(wsgem.balanceOf(address(sy)) + handler.ghostSmelted(), sy.totalSupply() + handler.ghostHealed());
    }

    function invariant_FailClosedEnforced() public view {
        assertEq(handler.depositAcceptedInDeficit(), 0, "deposit accepted during deficit");
        assertEq(handler.depositWrongError(), 0, "deficit deposit reverted with wrong error");
        assertEq(handler.redeemOverdrawn(), 0, "redeem past balance succeeded");
        assertEq(handler.redeemWrongError(), 0, "tail redeem reverted with wrong error");
    }

    /// @dev Deterministic wiring proof (see the healthy suite's twin): walks the full
    /// smelt lifecycle — healthy deposits, a smelt opening a deficit, a fail-closed
    /// deposit, remediation, and a reopened deposit — asserting every counter moved.
    function test_HandlerWiring_FullSmeltLifecycle() public {
        handler.depositGem(0, 5e18);
        handler.depositWsgem(1, 2e18);
        handler.redeem(0, 1e18);
        handler.poke(1e18);

        handler.smelt(1e18);
        assertEq(sy.deficit(), 1e18);
        handler.depositWsgem(2, 1e18); // must be refused, with the exact shortfall
        handler.heal(1e18);
        assertEq(sy.deficit(), 0);
        handler.depositWsgem(2, 1e18); // deficit cleared: deposits reopen

        assertEq(handler.depositOk(), 3);
        assertEq(handler.depositBlockedOk(), 1);
        assertEq(handler.redeemOk(), 1);
        assertEq(handler.smeltOk(), 1);
        assertEq(handler.healOk(), 1);
        assertEq(handler.pokeOk(), 1);
        assertEq(handler.depositAcceptedInDeficit(), 0);
        assertEq(handler.depositWrongError(), 0);
        assertEq(handler.redeemOverdrawn(), 0);
        assertEq(handler.redeemWrongError(), 0);
    }
}
