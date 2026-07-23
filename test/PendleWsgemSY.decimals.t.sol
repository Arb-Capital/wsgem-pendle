// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SYTestBase} from "./SYTestBase.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";

/// @notice Proof of the decimals-agnostic claim: navprice/mintcost are quoted in gem
/// native units per whole (1e18) wsgem, so gem decimals never enter the share math.
/// The same flow assertions run against 2-, 6-, and 8-decimal gems (the main suite
/// covers 18). The only decimals effect is economic quantization — value rounds down
/// to the gem's smallest unit, bounded below one unit per round trip — which the
/// round-trip fuzz pins down.
abstract contract WsgemDecimalsTest is SYTestBase {
    function _decimals() internal pure virtual returns (uint8);

    function _one() internal pure returns (uint256) {
        return 10 ** uint256(_decimals());
    }

    function setUp() public override {
        gemDecimals = _decimals();
        // ~1.006 gem per whole wsgem, expressed in gem native units.
        initNavprice = (1006 * _one()) / 1000;
        super.setUp();
    }

    function test_AssetInfoUsesGemDecimals() public view {
        (, address assetAddress, uint8 assetDecimals) = sy.assetInfo();
        assertEq(assetAddress, address(gem));
        assertEq(assetDecimals, _decimals());
        // SY shares mirror the wsgem and stay 18-decimal regardless of the gem.
        assertEq(sy.decimals(), 18);
    }

    function test_ExchangeRate_IsGemNativeUnits() public view {
        assertEq(sy.exchangeRate(), initNavprice);
    }

    function test_DepositGem_MintcostMintsOneWholeShare() public {
        uint256 unit = wsgem.mintcost();
        gem.mint(alice, unit);
        vm.startPrank(alice);
        gem.approve(address(sy), unit);
        assertEq(sy.deposit(alice, address(gem), unit, 0), 1e18);
        vm.stopPrank();
    }

    function test_DepositRedeemWsgem_OneToOne() public {
        uint256 amt = _mintWsgem(alice, 100 * _one());
        vm.startPrank(alice);
        wsgem.approve(address(sy), amt);
        uint256 shares = sy.deposit(alice, address(wsgem), amt, 0);
        assertEq(shares, amt);
        assertEq(sy.redeem(alice, shares, address(wsgem), 0, false), shares);
        vm.stopPrank();
        assertEq(wsgem.balanceOf(alice), amt);
    }

    function test_Dust_BelowMintcostReverts() public {
        uint256 unit = wsgem.mintcost();
        vm.expectRevert(abi.encodeWithSelector(IWsgem.DustThreshold.selector, unit));
        sy.previewDeposit(address(gem), unit - 1);
    }

    function testFuzz_PreviewDepositGem_MatchesDeposit(uint256 amt, uint256 navRaw, uint256 bpsin) public {
        // navprice in gem native units: 1 smallest unit up to 1e9 whole gems per wsgem.
        navRaw = bound(navRaw, 1, 1e9 * _one());
        bpsin = bound(bpsin, 0, 10000);
        pip.poke(navRaw);
        act.setBpsin(bpsin);

        uint256 unit = wsgem.mintcost();
        amt = bound(amt, unit, 1e12 * _one());

        uint256 preview = sy.previewDeposit(address(gem), amt);

        gem.mint(alice, amt);
        vm.startPrank(alice);
        gem.approve(address(sy), amt);
        assertEq(sy.deposit(alice, address(gem), amt, 0), preview);
        vm.stopPrank();
    }

    function testFuzz_RoundTrip_LossBoundedByQuantization(uint256 amt) public {
        // bpsin is 0 in the harness, so the only loss is floor rounding: the shares'
        // gem value may fall below the gem paid in by at most one gem smallest-unit
        // plus the sub-unit truncation of the share division.
        uint256 unit = wsgem.mintcost();
        amt = bound(amt, unit, 1e9 * _one());

        gem.mint(alice, amt);
        vm.startPrank(alice);
        gem.approve(address(sy), amt);
        uint256 shares = sy.deposit(alice, address(gem), amt, 0);
        vm.stopPrank();

        uint256 value = (shares * wsgem.navprice()) / 1e18;
        assertLe(value, amt);
        assertLe(amt - value, unit / 1e18 + 1);
    }
}

contract WsgemDecimals2Test is WsgemDecimalsTest {
    function _decimals() internal pure override returns (uint8) {
        return 2;
    }
}

contract WsgemDecimals6Test is WsgemDecimalsTest {
    function _decimals() internal pure override returns (uint8) {
        return 6;
    }
}

contract WsgemDecimals8Test is WsgemDecimalsTest {
    function _decimals() internal pure override returns (uint8) {
        return 8;
    }
}
