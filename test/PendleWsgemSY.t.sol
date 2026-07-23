// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SYTestBase} from "./SYTestBase.sol";
import {PendleWsgemSY} from "../src/PendleWsgemSY.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";
import {MockGem} from "./mocks/MockGem.sol";
import {IStandardizedYield} from "pendle-sy/interfaces/IStandardizedYield.sol";
import {Errors} from "pendle-sy/core/libraries/Errors.sol";

contract PendleWsgemSYTest is SYTestBase {
    /*///////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public view {
        assertEq(sy.name(), "SY Wrapped Staked Gem");
        assertEq(sy.symbol(), "SY-wsGEM");
        assertEq(sy.decimals(), 18);
        assertEq(sy.yieldToken(), address(wsgem));
        assertEq(sy.wsgem(), address(wsgem));
        assertEq(sy.gem(), address(gem));
    }

    function test_GemReadFromWsgem() public view {
        assertEq(sy.gem(), wsgem.gem());
    }

    function test_AssetInfo() public view {
        (IStandardizedYield.AssetType assetType, address assetAddress, uint8 assetDecimals) = sy.assetInfo();
        assertEq(uint8(assetType), uint8(IStandardizedYield.AssetType.TOKEN));
        assertEq(assetAddress, address(gem));
        assertEq(assetDecimals, 18);
    }

    function test_PricingInfo() public view {
        (address refToken, bool refStrictlyEqual) = sy.pricingInfo();
        assertEq(refToken, address(wsgem));
        assertTrue(refStrictlyEqual);
    }

    function test_GetTokensInOut() public view {
        address[] memory tokensIn = sy.getTokensIn();
        assertEq(tokensIn.length, 2);
        assertEq(tokensIn[0], address(wsgem));
        assertEq(tokensIn[1], address(gem));

        address[] memory tokensOut = sy.getTokensOut();
        assertEq(tokensOut.length, 1);
        assertEq(tokensOut[0], address(wsgem));
    }

    function test_IsValidTokenInOut() public {
        assertTrue(sy.isValidTokenIn(address(wsgem)));
        assertTrue(sy.isValidTokenIn(address(gem)));
        assertFalse(sy.isValidTokenIn(address(0)));
        assertFalse(sy.isValidTokenIn(makeAddr("random")));

        assertTrue(sy.isValidTokenOut(address(wsgem)));
        assertFalse(sy.isValidTokenOut(address(gem)));
        assertFalse(sy.isValidTokenOut(address(0)));
    }

    function test_OwnerIsDeployer() public view {
        assertEq(sy.owner(), address(this));
    }

    function test_ApprovalSetInConstructor() public view {
        assertEq(gem.allowance(address(sy), address(wsgem)), type(uint256).max);
    }

    /*///////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_DepositWsgem_OneToOne() public {
        uint256 amt = _mintWsgem(alice, 100e18);

        vm.startPrank(alice);
        wsgem.approve(address(sy), amt);
        uint256 shares = sy.deposit(alice, address(wsgem), amt, 0);
        vm.stopPrank();

        assertEq(shares, amt);
        assertEq(sy.balanceOf(alice), amt);
        assertEq(wsgem.balanceOf(address(sy)), amt);
    }

    function test_DepositGem_SharesEqualWsgemMintOutput() public {
        uint256 amt = 100e18;
        gem.mint(alice, amt);

        uint256 expected = (amt * 1e18) / wsgem.mintcost();

        vm.startPrank(alice);
        gem.approve(address(sy), amt);
        uint256 shares = sy.deposit(alice, address(gem), amt, 0);
        vm.stopPrank();

        assertEq(shares, expected);
        assertEq(sy.balanceOf(alice), shares);
        // The SY holds exactly `shares` wsgem and no stray gem.
        assertEq(wsgem.balanceOf(address(sy)), shares);
        assertEq(gem.balanceOf(address(sy)), 0);
        assertEq(gem.balanceOf(address(wsgem)), amt);
    }

    function test_Deposit_ToOtherReceiver() public {
        uint256 amt = _mintWsgem(alice, 10e18);
        vm.startPrank(alice);
        wsgem.approve(address(sy), amt);
        sy.deposit(bob, address(wsgem), amt, 0);
        vm.stopPrank();
        assertEq(sy.balanceOf(bob), amt);
        assertEq(sy.balanceOf(alice), 0);
    }

    function test_Deposit_ZeroReverts() public {
        vm.expectRevert(Errors.SYZeroDeposit.selector);
        sy.deposit(alice, address(wsgem), 0, 0);
    }

    function test_Deposit_InvalidTokenReverts() public {
        address bad = makeAddr("bad");
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInvalidTokenIn.selector, bad));
        sy.deposit(alice, bad, 1e18, 0);
    }

    function test_Deposit_MinSharesOutReverts() public {
        uint256 amt = _mintWsgem(alice, 10e18);
        vm.startPrank(alice);
        wsgem.approve(address(sy), amt);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInsufficientSharesOut.selector, amt, amt + 1));
        sy.deposit(alice, address(wsgem), amt, amt + 1);
        vm.stopPrank();
    }

    /*///////////////////////////////////////////////////////////////
                                REDEEM
    //////////////////////////////////////////////////////////////*/

    function _depositWsgemAs(address usr, uint256 gemIn) internal returns (uint256 shares) {
        uint256 amt = _mintWsgem(usr, gemIn);
        vm.startPrank(usr);
        wsgem.approve(address(sy), amt);
        shares = sy.deposit(usr, address(wsgem), amt, 0);
        vm.stopPrank();
    }

    function test_RedeemWsgem_OneToOne() public {
        uint256 shares = _depositWsgemAs(alice, 100e18);

        vm.prank(alice);
        uint256 out = sy.redeem(alice, shares, address(wsgem), 0, false);

        assertEq(out, shares);
        assertEq(sy.balanceOf(alice), 0);
        assertEq(wsgem.balanceOf(alice), shares);
        assertEq(wsgem.balanceOf(address(sy)), 0);
    }

    function test_Redeem_ToOtherReceiver() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        vm.prank(alice);
        sy.redeem(bob, shares, address(wsgem), 0, false);
        assertEq(wsgem.balanceOf(bob), shares);
    }

    function test_Redeem_BurnFromInternalBalance() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        // Simulate the router flow: shares are transferred to the SY first.
        vm.prank(alice);
        sy.transfer(address(sy), shares);

        vm.prank(bob);
        uint256 out = sy.redeem(alice, shares, address(wsgem), 0, true);
        assertEq(out, shares);
        assertEq(wsgem.balanceOf(alice), shares);
    }

    function test_Redeem_InvalidTokenOutReverts() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInvalidTokenOut.selector, address(gem)));
        sy.redeem(alice, shares, address(gem), 0, false);
    }

    function test_Redeem_ZeroReverts() public {
        vm.expectRevert(Errors.SYZeroRedeem.selector);
        sy.redeem(alice, 0, address(wsgem), 0, false);
    }

    function test_Redeem_MinTokenOutReverts() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInsufficientTokenOut.selector, shares, shares + 1));
        sy.redeem(alice, shares, address(wsgem), shares + 1, false);
    }

    /*///////////////////////////////////////////////////////////////
                            PREVIEW PARITY
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PreviewDepositWsgem_MatchesDeposit(uint256 amt) public {
        amt = bound(amt, 1, 1e30);
        uint256 preview = sy.previewDeposit(address(wsgem), amt);

        uint256 got = _mintWsgem(alice, (amt * wsgem.mintcost()) / 1e18 + wsgem.mintcost());
        vm.assume(got >= amt);
        vm.startPrank(alice);
        wsgem.approve(address(sy), amt);
        uint256 shares = sy.deposit(alice, address(wsgem), amt, 0);
        vm.stopPrank();

        assertEq(preview, shares);
    }

    function testFuzz_PreviewDepositGem_MatchesDeposit(uint256 amt, uint256 navprice, uint256 bpsin) public {
        navprice = bound(navprice, 1, 1e27);
        bpsin = bound(bpsin, 0, 10000);
        pip.poke(navprice);
        act.setBpsin(bpsin);

        uint256 unit = wsgem.mintcost();
        amt = bound(amt, unit, 1e30);

        uint256 preview = sy.previewDeposit(address(gem), amt);

        gem.mint(alice, amt);
        vm.startPrank(alice);
        gem.approve(address(sy), amt);
        uint256 shares = sy.deposit(alice, address(gem), amt, 0);
        vm.stopPrank();

        assertEq(preview, shares);
    }

    function test_PreviewDepositGem_ExactVectors() public {
        // amt == mintcost mints exactly one whole wsgem (bpsin = 0 => unit == navprice).
        assertEq(sy.previewDeposit(address(gem), wsgem.mintcost()), 1e18);

        // Odd navprice exercises divup in mintcost and floor in the share division.
        pip.poke(1e18 + 1);
        act.setBpsin(25);
        uint256 unit = wsgem.mintcost();
        uint256 raw = (1e18 + 1) * 10025 + 9999;
        assertEq(unit, raw / 10000);
        uint256 amt = 7919e15; // prime-ish amount above the dust threshold
        assertGe(amt, unit);
        assertEq(sy.previewDeposit(address(gem), amt), (amt * 1e18) / unit);
    }

    function testFuzz_PreviewRedeem_MatchesRedeem(uint256 amt) public {
        amt = bound(amt, 1, 1e27);
        uint256 got = _mintWsgem(alice, (amt * wsgem.mintcost()) / 1e18 + wsgem.mintcost());
        vm.assume(got >= amt);
        vm.startPrank(alice);
        wsgem.approve(address(sy), amt);
        sy.deposit(alice, address(wsgem), amt, 0);

        // Preview is balance-aware: exact quote up to holdings, revert past them.
        uint256 preview = sy.previewRedeem(address(wsgem), amt);
        vm.stopPrank();
        assertEq(preview, amt);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, 1));
        sy.previewRedeem(address(wsgem), amt + 1);

        vm.prank(alice);
        uint256 out = sy.redeem(alice, amt, address(wsgem), 0, false);
        assertEq(out, preview);
    }

    /*///////////////////////////////////////////////////////////////
                             EXCHANGE RATE
    //////////////////////////////////////////////////////////////*/

    function test_ExchangeRate_EqualsNavprice() public view {
        assertEq(sy.exchangeRate(), wsgem.navprice());
        assertEq(sy.exchangeRate(), INIT_NAVPRICE);
    }

    function test_ExchangeRate_TracksPokeUpAndDown() public {
        pip.poke(1.1e18);
        assertEq(sy.exchangeRate(), 1.1e18);
        pip.poke(0.9e18);
        assertEq(sy.exchangeRate(), 0.9e18);
    }

    function test_ExchangeRate_RevertsWhenOraclePaused() public {
        pip.pause();
        vm.expectRevert(IWsgem.InvalidPrice.selector);
        sy.exchangeRate();
    }

    /*///////////////////////////////////////////////////////////////
                        EDGE CASES: ORACLE / MARKET
    //////////////////////////////////////////////////////////////*/

    function test_OraclePaused_DepositGemReverts_WsgemPathsStillWork() public {
        uint256 wamt = _mintWsgem(alice, 10e18);
        gem.mint(alice, 10e18);
        pip.pause();

        // Gem deposit reverts in preview and in execution with the same selector.
        vm.expectRevert(IWsgem.InvalidPrice.selector);
        sy.previewDeposit(address(gem), 10e18);

        vm.startPrank(alice);
        gem.approve(address(sy), 10e18);
        vm.expectRevert(IWsgem.InvalidPrice.selector);
        sy.deposit(alice, address(gem), 10e18, 0);

        // wsgem deposit and redeem remain fully functional.
        wsgem.approve(address(sy), wamt);
        uint256 shares = sy.deposit(alice, address(wsgem), wamt, 0);
        assertEq(shares, wamt);
        uint256 out = sy.redeem(alice, shares, address(wsgem), 0, false);
        assertEq(out, wamt);
        vm.stopPrank();
    }

    function test_MarketClosed_DepositGemReverts_WsgemUnaffected() public {
        uint256 wamt = _mintWsgem(alice, 10e18);
        gem.mint(alice, 10e18);
        act.pauseMarket();

        vm.expectRevert(IWsgem.MarketClosed.selector);
        sy.previewDeposit(address(gem), 10e18);

        vm.startPrank(alice);
        gem.approve(address(sy), 10e18);
        vm.expectRevert(IWsgem.MarketClosed.selector);
        sy.deposit(alice, address(gem), 10e18, 0);

        wsgem.approve(address(sy), wamt);
        assertEq(sy.deposit(alice, address(wsgem), wamt, 0), wamt);
        vm.stopPrank();
    }

    function test_Dust_BelowMintcostReverts_AtMintcostSucceeds() public {
        uint256 unit = wsgem.mintcost();
        gem.mint(alice, unit);

        vm.expectRevert(abi.encodeWithSelector(IWsgem.DustThreshold.selector, unit));
        sy.previewDeposit(address(gem), unit - 1);

        vm.startPrank(alice);
        gem.approve(address(sy), unit);
        vm.expectRevert(abi.encodeWithSelector(IWsgem.DustThreshold.selector, unit));
        sy.deposit(alice, address(gem), unit - 1, 0);

        assertEq(sy.deposit(alice, address(gem), unit, 0), 1e18);
        vm.stopPrank();
    }

    function test_CapacityExceededReverts() public {
        act.setCapacity(1e18);
        uint256 amt = 10e18;
        gem.mint(alice, amt);

        vm.expectRevert(IWsgem.ExceedsCap.selector);
        sy.previewDeposit(address(gem), amt);

        vm.startPrank(alice);
        gem.approve(address(sy), amt);
        vm.expectRevert(IWsgem.ExceedsCap.selector);
        sy.deposit(alice, address(gem), amt, 0);
        vm.stopPrank();
    }

    /*///////////////////////////////////////////////////////////////
                        EDGE CASES: COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_BannedSY_DepositGemReverts() public {
        gem.mint(alice, 10e18);
        gem.ban(address(sy));

        vm.startPrank(alice);
        gem.approve(address(sy), 10e18);
        vm.expectRevert(abi.encodeWithSelector(IWsgem.NotAuthorized.selector, address(sy)));
        sy.deposit(alice, address(gem), 10e18, 0);
        vm.stopPrank();
    }

    function test_BannedSY_DepositWsgemReverts() public {
        uint256 amt = _mintWsgem(alice, 10e18);
        // Approve before banning: wsgem.approve screens the spender too.
        vm.prank(alice);
        wsgem.approve(address(sy), amt);
        gem.ban(address(sy));

        // wsgem.transferFrom screens dst == SY.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWsgem.NotAuthorized.selector, address(sy)));
        sy.deposit(alice, address(wsgem), amt, 0);
    }

    function test_BannedUser_DepositWsgemReverts() public {
        uint256 amt = _mintWsgem(alice, 10e18);
        vm.prank(alice);
        wsgem.approve(address(sy), amt);
        gem.ban(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWsgem.NotAuthorized.selector, alice));
        sy.deposit(alice, address(wsgem), amt, 0);
    }

    function test_RedeemToBannedReceiverReverts() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        gem.ban(bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWsgem.NotAuthorized.selector, bob));
        sy.redeem(bob, shares, address(wsgem), 0, false);
    }

    function test_BannedSY_RedeemFrozen_UnbanRestores() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        gem.ban(address(sy));

        // wsgem.transfer screens src == SY: redemptions freeze while the ban lasts.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWsgem.NotAuthorized.selector, address(sy)));
        sy.redeem(alice, shares, address(wsgem), 0, false);

        gem.unban(address(sy));
        vm.prank(alice);
        assertEq(sy.redeem(alice, shares, address(wsgem), 0, false), shares);
    }

    function test_BannedHolder_SySharesStillTransferable() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        gem.ban(alice);

        // SY shares are plain PendleERC20 — not compliance-gated.
        vm.prank(alice);
        sy.transfer(bob, shares);
        assertEq(sy.balanceOf(bob), shares);
    }

    /*///////////////////////////////////////////////////////////////
                EDGE CASES: PRIVILEGED SMELT / SOLVENCY
    //////////////////////////////////////////////////////////////*/

    function test_Deficit_ZeroInNormalOperation() public {
        assertEq(sy.deficit(), 0);
        _depositWsgemAs(alice, 100e18);
        assertEq(sy.deficit(), 0);
    }

    function test_IssuerSmelt_CreatesDeficit_BlocksDeposits() public {
        uint256 shares = _depositWsgemAs(alice, 100e18);

        // Privileged burn of part of the SY's wsgem backing.
        uint256 burned = 40e18;
        vm.prank(issuer);
        wsgem.smelt(address(sy), burned);

        assertEq(sy.deficit(), burned);

        // Previews and deposits fail closed with the same selector, on both routes.
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, burned));
        sy.previewDeposit(address(wsgem), 1e18);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, burned));
        sy.previewDeposit(address(gem), 1e18);

        uint256 wamt = _mintWsgem(bob, 10e18);
        gem.mint(bob, 10e18);
        vm.startPrank(bob);
        wsgem.approve(address(sy), wamt);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, burned));
        sy.deposit(bob, address(wsgem), wamt, 0);
        gem.approve(address(sy), 10e18);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, burned));
        sy.deposit(bob, address(gem), 10e18, 0);
        vm.stopPrank();

        // Redemptions stay live but are first-come: what remains is redeemable,
        // the tail is not — and previews agree on both sides of the line.
        uint256 remaining = wsgem.balanceOf(address(sy));
        assertEq(sy.previewRedeem(address(wsgem), remaining), remaining);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, 1));
        sy.previewRedeem(address(wsgem), remaining + 1);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, burned));
        sy.previewRedeem(address(wsgem), shares);

        vm.prank(alice);
        uint256 out = sy.redeem(alice, remaining, address(wsgem), 0, false);
        assertEq(out, remaining);

        // Execution parity: the tail redeem reverts with the same SYInsolvent the
        // preview quotes (balance is zero after the first-come redemption above).
        uint256 tail = shares - remaining;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, tail));
        sy.redeem(alice, tail, address(wsgem), 0, false);
    }

    function test_Insolvent_ErrorOrderingMatchesPreview() public {
        _depositWsgemAs(alice, 100e18);
        vm.prank(issuer);
        wsgem.smelt(address(sy), 40e18);

        gem.mint(bob, 10e18);
        vm.prank(bob);
        gem.approve(address(sy), 10e18);

        // Deficit + closed market: SYInsolvent wins in preview AND execution
        // (execution checks solvency before touching wsgem.mint()).
        act.pauseMarket();
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, 40e18));
        sy.previewDeposit(address(gem), 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, 40e18));
        sy.deposit(bob, address(gem), 10e18, 0);

        // Deficit + paused oracle: same story.
        act.setOpenMint(block.timestamp);
        act.file("haltmint", type(uint256).max);
        pip.pause();
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, 40e18));
        sy.previewDeposit(address(gem), 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, 40e18));
        sy.deposit(bob, address(gem), 10e18, 0);
    }

    function test_Deficit_ClearedRestoresDeposits() public {
        _depositWsgemAs(alice, 100e18);
        vm.prank(issuer);
        wsgem.smelt(address(sy), 40e18);
        assertEq(sy.deficit(), 40e18);

        // Backfilling the SY's wsgem balance (e.g. issuer remediation) clears the
        // deficit and reopens deposits.
        uint256 refill = _mintWsgem(bob, 41e18);
        assertGe(refill, 40e18);
        vm.prank(bob);
        wsgem.transfer(address(sy), 40e18);

        assertEq(sy.deficit(), 0);
        assertEq(sy.previewDeposit(address(wsgem), 1e18), 1e18);

        uint256 wamt = refill - 40e18;
        vm.startPrank(bob);
        wsgem.approve(address(sy), wamt);
        assertEq(sy.deposit(bob, address(wsgem), wamt, 0), wamt);
        vm.stopPrank();
    }

    /*///////////////////////////////////////////////////////////////
                                 SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_Sweep_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        sy.sweep(address(gem), alice);
    }

    function test_Sweep_WsgemAlwaysReverts_EvenForSurplus() public {
        _depositWsgemAs(alice, 10e18);
        // Donated surplus is extra backing (donations are how a post-smelt deficit is
        // remediated), not sweepable value.
        uint256 donation = _mintWsgem(bob, 5e18);
        vm.prank(bob);
        wsgem.transfer(address(sy), donation);
        assertGt(wsgem.balanceOf(address(sy)), sy.totalSupply());

        vm.expectRevert(PendleWsgemSY.SweepBackingToken.selector);
        sy.sweep(address(wsgem), address(this));
    }

    function test_Sweep_WsgemBlockedDuringDeficitToo() public {
        _depositWsgemAs(alice, 100e18);
        vm.prank(issuer);
        wsgem.smelt(address(sy), 40e18);

        vm.expectRevert(PendleWsgemSY.SweepBackingToken.selector);
        sy.sweep(address(wsgem), address(this));
    }

    function test_Sweep_RecoversDirectlyTransferredGem() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        gem.mint(address(sy), 5e18); // mistaken direct transfer instead of deposit()

        vm.expectEmit(true, true, true, true);
        emit PendleWsgemSY.Sweep(address(gem), bob, 5e18);
        sy.sweep(address(gem), bob);

        assertEq(gem.balanceOf(bob), 5e18);
        assertEq(gem.balanceOf(address(sy)), 0);
        // Backing untouched: still fully redeemable 1:1.
        assertEq(sy.deficit(), 0);
        vm.prank(alice);
        assertEq(sy.redeem(alice, shares, address(wsgem), 0, false), shares);
    }

    function test_Sweep_RecoversUnrelatedToken() public {
        MockGem rando = new MockGem(18);
        rando.mint(address(sy), 7e18);
        sy.sweep(address(rando), bob);
        assertEq(rando.balanceOf(bob), 7e18);
    }

    function test_Sweep_RecoversEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(sy).call{value: 1 ether}("");
        assertTrue(ok);

        sy.sweep(address(0), bob);
        assertEq(bob.balance, 1 ether);
        assertEq(address(sy).balance, 0);
    }

    function test_Sweep_ZeroBalanceIsNoop() public {
        sy.sweep(address(gem), bob);
        assertEq(gem.balanceOf(bob), 0);
    }

    function test_Sweep_WorksWhilePaused() public {
        gem.mint(address(sy), 1e18);
        sy.pause();
        sy.sweep(address(gem), bob);
        assertEq(gem.balanceOf(bob), 1e18);
    }

    /*///////////////////////////////////////////////////////////////
                        SY PAUSE / OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function test_Pause_BlocksDepositRedeemTransfer() public {
        uint256 shares = _depositWsgemAs(alice, 10e18);
        uint256 wamt = _mintWsgem(alice, 10e18);

        sy.pause();

        vm.startPrank(alice);
        wsgem.approve(address(sy), wamt);
        vm.expectRevert("Pausable: paused");
        sy.deposit(alice, address(wsgem), wamt, 0);

        vm.expectRevert("Pausable: paused");
        sy.redeem(alice, shares, address(wsgem), 0, false);

        vm.expectRevert("Pausable: paused");
        sy.transfer(bob, shares);
        vm.stopPrank();

        sy.unpause();
        vm.prank(alice);
        uint256 out = sy.redeem(alice, shares, address(wsgem), 0, false);
        assertEq(out, shares);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        sy.pause();
    }

    function test_TransferOwnership_TwoStep() public {
        sy.transferOwnership(alice, false, false);
        assertEq(sy.owner(), address(this));
        assertEq(sy.pendingOwner(), alice);

        vm.prank(alice);
        sy.claimOwnership();
        assertEq(sy.owner(), alice);
    }
}
