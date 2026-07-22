// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {PendleWsgemSY} from "../src/PendleWsgemSY.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/// @notice Deterministic mainnet-fork suite exercising the generic SY against the live
/// wstGBP deployment (the first wsgem instance) at a PINNED block, so results never
/// drift with live state and RPC responses cache. Skips without an explicit RPC (see
/// {ForkBase}). Latest-state checks live in PendleWsgemSY.smoke.t.sol.
contract PendleWsgemSYForkTest is ForkBase {
    // Live instance under test: wstGBP / tGBP on Ethereum mainnet.
    address constant WSGEM = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address constant GEM = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;

    /// @dev 2026-07-22. The wsgem market is open with cooldown 0 at this block; bump
    /// deliberately (or via FORK_BLOCK) when a new baseline is wanted. Historical
    /// state needs an archive-capable RPC — any Alchemy/Infura endpoint qualifies.
    uint256 constant PINNED_BLOCK = 25_589_900;

    PendleWsgemSY internal sy;
    address internal alice = makeAddr("alice");

    function setUp() public {
        if (!_forkOrSkip(vm.envOr("FORK_BLOCK", uint256(PINNED_BLOCK)))) return;
        // Deploying at all proves the constructor's gem() read and the gem
        // infinite-approve succeed against the live token.
        sy = new PendleWsgemSY("SY Wren Staked tGBP", "SY-wstGBP", WSGEM);
    }

    function testFork_LiveMetadata() public onlyFork {
        assertEq(sy.gem(), GEM);
        assertEq(sy.yieldToken(), WSGEM);
        assertEq(sy.decimals(), 18);
        assertEq(IERC20Like(GEM).decimals(), 18);
        assertEq(IERC20Like(WSGEM).name(), "Wren Staked tGBP");
        assertEq(IERC20Like(WSGEM).symbol(), "wstGBP");
    }

    function testFork_ExchangeRate_EqualsNavprice() public onlyFork {
        assertEq(sy.exchangeRate(), IWsgem(WSGEM).navprice());
        assertGt(sy.exchangeRate(), 0);
    }

    function testFork_DepositGem_E2E_PreviewParity() public onlyFork {
        uint256 amt = 10_000e18;
        deal(GEM, alice, amt);

        uint256 preview = sy.previewDeposit(GEM, amt);

        vm.startPrank(alice);
        IERC20Like(GEM).approve(address(sy), amt);
        uint256 shares = sy.deposit(alice, GEM, amt, 0);
        vm.stopPrank();

        assertEq(shares, preview);
        assertEq(sy.balanceOf(alice), shares);
        assertEq(IERC20Like(WSGEM).balanceOf(address(sy)), shares);
        assertEq(IERC20Like(GEM).balanceOf(address(sy)), 0);
    }

    function testFork_DepositWsgem_RedeemRoundTrip() public onlyFork {
        // Acquire wsgem the canonical way: gem -> wsgem.mint().
        uint256 amt = 5_000e18;
        deal(GEM, alice, amt);
        vm.startPrank(alice);
        IERC20Like(GEM).approve(WSGEM, amt);
        uint256 wamt = IWsgem(WSGEM).mint(amt);

        IERC20Like(WSGEM).approve(address(sy), wamt);
        uint256 shares = sy.deposit(alice, WSGEM, wamt, 0);
        assertEq(shares, wamt);

        uint256 out = sy.redeem(alice, shares, WSGEM, 0, false);
        vm.stopPrank();

        assertEq(out, wamt);
        assertEq(IERC20Like(WSGEM).balanceOf(alice), wamt);
        assertEq(sy.totalSupply(), 0);
    }
}
