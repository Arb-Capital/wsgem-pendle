// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SYTestBase} from "./SYTestBase.sol";
import {DeployPendleWsgemSY} from "../script/DeployPendleWsgemSY.s.sol";
import {PendleWsgemSY} from "../src/PendleWsgemSY.sol";
import {MaseerOne as Wsgem} from "maseer-one/MaseerOne.sol";
import {MockGem} from "./mocks/MockGem.sol";

/// @notice Executes the deploy script end to end against the local wsgem stack. The
/// pre-deployment review found the script's sanity battery could never pass on a fresh
/// SY and nothing exercised it; this suite keeps every script path executable. The
/// script is driven through deploy()/check() directly (run() is a thin env-var reader
/// over deploy(); vm.setEnv races across parallel tests, so env parsing stays untested
/// by design).
contract DeployPendleWsgemSYTest is SYTestBase {
    DeployPendleWsgemSY internal deployer;
    address internal multisig = makeAddr("multisig");

    function setUp() public override {
        super.setUp();
        deployer = new DeployPendleWsgemSY();
    }

    function _deploy(address owner) internal returns (PendleWsgemSY dsy) {
        dsy = deployer.deploy(address(wsgem), "SY Wrapped Staked Gem", "SY-wsGEM", address(gem), owner);
    }

    function _depositInto(PendleWsgemSY dsy, uint256 gemIn) internal returns (uint256 shares) {
        uint256 amt = _mintWsgem(alice, gemIn);
        vm.startPrank(alice);
        wsgem.approve(address(dsy), amt);
        shares = dsy.deposit(alice, address(wsgem), amt, 0);
        vm.stopPrank();
    }

    function test_Deploy_FreshInstancePassesSanity() public {
        PendleWsgemSY dsy = _deploy(address(0));
        assertEq(dsy.name(), "SY Wrapped Staked Gem");
        assertEq(dsy.symbol(), "SY-wsGEM");
        assertEq(dsy.wsgem(), address(wsgem));
        assertEq(dsy.gem(), address(gem));
        assertEq(dsy.totalSupply(), 0);
        assertEq(dsy.deficit(), 0);
    }

    function test_Deploy_TwoStepOwnership() public {
        PendleWsgemSY dsy = _deploy(multisig);
        // Ownership must NOT move until the new owner proves liveness by claiming.
        assertTrue(dsy.owner() != multisig);
        assertEq(dsy.pendingOwner(), multisig);

        vm.prank(multisig);
        dsy.claimOwnership();
        assertEq(dsy.owner(), multisig);
    }

    function test_Deploy_RequiresExplicitName() public {
        vm.expectRevert("SY_NAME required");
        deployer.deploy(address(wsgem), "", "SY-wsGEM", address(gem), address(0));
    }

    function test_Deploy_RequiresExplicitSymbol() public {
        vm.expectRevert("SY_SYMBOL required");
        deployer.deploy(address(wsgem), "SY Wrapped Staked Gem", "", address(gem), address(0));
    }

    function test_Deploy_RequiresExpectedGem() public {
        vm.expectRevert("EXPECTED_GEM required");
        deployer.deploy(address(wsgem), "SY Wrapped Staked Gem", "SY-wsGEM", address(0), address(0));
    }

    function test_Deploy_GemMismatchAborts() public {
        vm.expectRevert("wsgem.gem() != EXPECTED_GEM");
        deployer.deploy(address(wsgem), "SY Wrapped Staked Gem", "SY-wsGEM", makeAddr("wrongGem"), address(0));
    }

    function test_Deploy_OraclePausedAborts() public {
        pip.pause();
        vm.expectRevert("oracle paused");
        _deploy(address(0));
    }

    function test_Deploy_MintWindowClosed_StillDeploys() public {
        // The gem-route preview check is skipped (with a warning) when the wsgem mint
        // window is closed; deployment itself must not depend on the window.
        act.pauseMarket();
        PendleWsgemSY dsy = _deploy(address(0));
        assertEq(dsy.wsgem(), address(wsgem));
    }

    function _check(PendleWsgemSY dsy) internal view {
        deployer.check(address(dsy), address(wsgem), address(gem), address(0));
    }

    function test_Check_FreshInstance() public {
        PendleWsgemSY dsy = _deploy(address(0));
        _check(dsy);
    }

    function test_Check_ActiveInstance() public {
        PendleWsgemSY dsy = _deploy(address(0));
        _depositInto(dsy, 25e18);
        _check(dsy);
    }

    function test_Check_FlagsDeficit() public {
        PendleWsgemSY dsy = _deploy(address(0));
        uint256 shares = _depositInto(dsy, 25e18);

        vm.prank(issuer);
        wsgem.smelt(address(dsy), shares / 2);

        vm.expectRevert("deficit != 0");
        _check(dsy);
    }

    function test_Check_FlagsPaused() public {
        PendleWsgemSY dsy = _deploy(address(0));
        vm.prank(dsy.owner());
        dsy.pause();

        vm.expectRevert("SY paused");
        _check(dsy);
    }

    function test_Check_FlagsUnexpectedPendingOwner() public {
        PendleWsgemSY dsy = _deploy(multisig);
        vm.prank(multisig);
        dsy.claimOwnership();
        // Expected owner active, pending slot empty: healthy.
        deployer.check(address(dsy), address(wsgem), address(gem), multisig);

        // A transfer parked toward any other address must flag, even though the
        // expected owner still holds the contract.
        vm.prank(multisig);
        dsy.transferOwnership(makeAddr("attacker"), false, false);
        vm.expectRevert("unexpected pending owner");
        deployer.check(address(dsy), address(wsgem), address(gem), multisig);
    }

    function test_Check_FlagsPendingOwnerWithoutExpectedOwner() public {
        // The default invocation (no SY_OWNER declared) must still refuse a parked
        // transfer: the pending owner could claim control unilaterally.
        PendleWsgemSY dsy = _deploy(address(0));
        vm.prank(dsy.owner());
        dsy.transferOwnership(makeAddr("attacker"), false, false);

        vm.expectRevert("unexpected pending owner");
        _check(dsy);
    }

    function test_Check_RejectsWrongSY() public {
        // A perfectly healthy SY bound to a DIFFERENT wsgem must not pass a check
        // that expects ours: the expected wsgem comes from outside, never from the
        // SY under check.
        MockGem gem2 = new MockGem(18);
        Wsgem wsgem2 = new Wsgem(address(gem2), address(pip), address(act), address(adm), address(cop), flo, "W2", "W2");
        PendleWsgemSY other = deployer.deploy(address(wsgem2), "SY W2", "SY-W2", address(gem2), address(0));

        vm.expectRevert("yieldToken");
        deployer.check(address(other), address(wsgem), address(gem), address(0));
    }

    function test_Check_RequiresExpectedGem() public {
        PendleWsgemSY dsy = _deploy(address(0));
        vm.expectRevert("EXPECTED_GEM required");
        deployer.check(address(dsy), address(wsgem), address(0), address(0));
    }
}
