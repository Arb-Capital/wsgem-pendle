// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MaseerOne as Wsgem} from "maseer-one/MaseerOne.sol";
import {MaseerPrice} from "maseer-one/MaseerPrice.sol";
import {MaseerGate} from "maseer-one/MaseerGate.sol";
import {MaseerGuardOZ} from "maseer-one/MaseerGuardOZ.sol";
import {MaseerTreasury} from "maseer-one/MaseerTreasury.sol";

/// @dev MaseerTreasury is proxy-only upstream (no self-rely constructor, unlike
/// MaseerPrice/MaseerGate); this harness adds the same deployer-rely the siblings have
/// so it can be used directly in tests.
contract TreasuryHarness is MaseerTreasury {
    constructor() {
        _rely(msg.sender);
    }
}
import {PendleWsgemSY} from "../src/PendleWsgemSY.sol";
import {MockGem} from "./mocks/MockGem.sol";

/// @notice Deploys the real wsgem stack (token, oracle, gate, guard) around a mock gem,
/// configured to mirror the live wstGBP deployment: bpsin 0, bpsout 25, cooldown 0,
/// capacity max, windows open indefinitely, navprice ~1.006 WAD.
abstract contract SYTestBase is Test {
    uint256 internal constant INIT_NAVPRICE = 1.006e18;

    // Overridable before super.setUp() — the decimals suite deploys the same stack
    // around a low-decimal gem (navprice is quoted in gem native units per whole
    // wsgem, so it must be rescaled alongside).
    uint8 internal gemDecimals = 18;
    uint256 internal initNavprice = INIT_NAVPRICE;

    MockGem internal gem;
    MaseerPrice internal pip;
    MaseerGate internal act;
    MaseerGuardOZ internal cop;
    TreasuryHarness internal adm;
    Wsgem internal wsgem;
    PendleWsgemSY internal sy;

    address internal issuer = makeAddr("issuer");
    address internal flo = makeAddr("flo");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        gem = new MockGem(gemDecimals);

        pip = new MaseerPrice();
        pip.kiss(address(this));
        pip.poke(initNavprice);

        act = new MaseerGate();
        act.setOpenMint(block.timestamp);
        act.setOpenBurn(block.timestamp);
        // setHaltMint/setHaltBurn cap at now+365d; file() is how the live deployment
        // set the windows to be open indefinitely.
        act.file("haltmint", type(uint256).max);
        act.file("haltburn", type(uint256).max);
        act.setBpsin(0);
        act.setBpsout(25);
        act.setCooldown(0);
        act.setCapacity(type(uint256).max);

        cop = new MaseerGuardOZ(address(gem));

        adm = new TreasuryHarness();
        adm.bestow(issuer);

        wsgem = new Wsgem(
            address(gem), address(pip), address(act), address(adm), address(cop), flo, "Wrapped Staked Gem", "wsGEM"
        );

        sy = new PendleWsgemSY("SY Wrapped Staked Gem", "SY-wsGEM", address(wsgem));
    }

    function _mintGem(address usr, uint256 amt) internal {
        gem.mint(usr, amt);
    }

    function _mintWsgem(address usr, uint256 gemIn) internal returns (uint256 out) {
        gem.mint(usr, gemIn);
        vm.startPrank(usr);
        gem.approve(address(wsgem), gemIn);
        out = wsgem.mint(gemIn);
        vm.stopPrank();
    }
}
