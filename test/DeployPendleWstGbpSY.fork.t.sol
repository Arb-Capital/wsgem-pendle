// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {DeployPendleWstGbpSY} from "../script/DeployPendleWstGbpSY.s.sol";
import {PendleWsgemSY} from "../src/PendleWsgemSY.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";

interface IERC20MetaLike {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/// @notice Validates the pinned wstGBP deploy script against the live Ethereum mainnet
/// instance it hardcodes — the only place its constants can actually be wrong. The
/// generic deploy/check machinery is covered offline in DeployPendleWsgemSYTest; here we
/// prove the pinned values name the real wstGBP/tGBP pair and that the script deploys
/// and self-checks against live state. Skips without an explicit RPC (see {ForkBase}).
contract DeployPendleWstGbpSYForkTest is ForkBase {
    /// @dev Same baseline as PendleWsgemSYForkTest: wsgem market open, cooldown 0.
    uint256 constant PINNED_BLOCK = 25_589_900;

    DeployPendleWstGbpSY internal deployer;

    function setUp() public {
        if (!_forkOrSkip(vm.envOr("FORK_BLOCK", uint256(PINNED_BLOCK)))) return;
        deployer = new DeployPendleWstGbpSY();
    }

    /// @dev A typo in either pinned address is unrecoverable after broadcast: the wrong
    /// wsgem is wrapped forever, and the gem cross-check would be validating the wrong
    /// pair. Both are checked against the live tokens' own metadata.
    function testFork_PinnedAddressesAreTheLiveInstance() public onlyFork {
        assertEq(IERC20MetaLike(deployer.WSTGBP()).symbol(), "wstGBP");
        assertEq(IERC20MetaLike(deployer.TGBP()).symbol(), "tGBP");
        assertEq(IWsgem(deployer.WSTGBP()).gem(), deployer.TGBP());
    }

    /// @dev The SY metadata is likewise immutable once constructed, and must mirror the
    /// live token it wraps rather than drift from it.
    function testFork_PinnedMetadataMirrorsLiveToken() public onlyFork {
        assertEq(deployer.SY_NAME(), string.concat("SY ", IERC20MetaLike(deployer.WSTGBP()).name()));
        assertEq(deployer.SY_SYMBOL(), string.concat("SY-", IERC20MetaLike(deployer.WSTGBP()).symbol()));
    }

    /// @dev The pinned owner must be the live ops multisig, not a mistyped address: only a
    /// contract that can actually execute `claimOwnership()` completes the two-step
    /// transfer, and an EOA-shaped typo would silently leave the SY with the deployer.
    function testFork_PinnedOwnerIsALiveContract() public onlyFork {
        assertGt(deployer.OPS_OWNER().code.length, 0);
    }

    /// @dev The run() path end to end, minus the broadcast: pinned configuration in, live
    /// deployment out, and the script's own sanity battery green on the fresh instance.
    /// Note this reads WSGEM / EXPECTED_GEM / SY_NAME / SY_SYMBOL from the environment
    /// only to refuse contradicting values, so a stale export for another instance fails
    /// here exactly as it would at deploy time — which is the intent.
    function testFork_DeploysAndSelfChecks() public onlyFork {
        (address wsgem, address expectedGem, address owner) = deployer.target();
        (string memory name, string memory symbol) = deployer.naming();
        assertEq(wsgem, deployer.WSTGBP());
        assertEq(expectedGem, deployer.TGBP());
        assertEq(owner, vm.envOr("SY_OWNER", deployer.OPS_OWNER()));

        PendleWsgemSY sy = deployer.deploy(wsgem, name, symbol, expectedGem, owner);
        assertEq(sy.name(), deployer.SY_NAME());
        assertEq(sy.symbol(), deployer.SY_SYMBOL());
        assertEq(sy.wsgem(), deployer.WSTGBP());
        assertEq(sy.gem(), deployer.TGBP());

        deployer.check(address(sy), wsgem, expectedGem, owner);

        if (owner == address(0)) {
            // SY_OWNER overridden to the full zero address: no transfer was started and
            // the deployer keeps the contract. Claiming must NOT be simulated here —
            // claimOwnership() only checks `msg.sender == pendingOwner`, so a prank from
            // address(0) against an empty pending slot would renounce ownership outright.
            // No real caller can do that, and asserting it would green-light the very
            // state this branch exists to rule out.
            assertEq(sy.pendingOwner(), address(0));
            assertTrue(sy.owner() != address(0));
            return;
        }

        // Ownership is parked, not moved: the state make check expects until the
        // multisig claims.
        assertEq(sy.pendingOwner(), owner);
        assertTrue(sy.owner() != owner);
        vm.prank(owner);
        sy.claimOwnership();
        assertEq(sy.owner(), owner);
        deployer.check(address(sy), wsgem, expectedGem, owner);
    }
}
