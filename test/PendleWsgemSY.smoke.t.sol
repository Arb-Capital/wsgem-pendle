// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {PendleWsgemSY} from "../src/PendleWsgemSY.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";

/// @notice Latest-block smoke checks against the live wstGBP deployment. These assert
/// the CURRENT mainnet configuration (fees, cooldown, open market, compliance) — a
/// failure here means live governable parameters moved, not that the SY code
/// regressed. Deliberately separate from the pinned, deterministic fork suite.
/// Skips without an explicit RPC (see {ForkBase}).
contract PendleWsgemSYSmokeTest is ForkBase {
    address constant WSGEM = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;

    PendleWsgemSY internal sy;

    function setUp() public {
        if (!_forkOrSkip(0)) return; // latest block, intentionally
        sy = new PendleWsgemSY("SY Wren Staked tGBP", "SY-wstGBP", WSGEM);
    }

    function testSmoke_LiveParameters() public onlyFork {
        IWsgem w = IWsgem(WSGEM);
        assertGt(w.navprice(), 0, "oracle paused");
        assertGe(w.mintcost(), w.navprice(), "bpsin negative?");
        assertLe(w.burncost(), w.navprice(), "bpsout negative?");
        assertTrue(w.canPass(address(sy)), "SY banned on compliance list");
        assertEq(w.cooldown(), 0, "cooldown no longer atomic");
        assertTrue(w.mintable(), "mint window closed");
    }

    function testSmoke_ExchangeRateLive() public onlyFork {
        assertEq(sy.exchangeRate(), IWsgem(WSGEM).navprice());
    }
}
