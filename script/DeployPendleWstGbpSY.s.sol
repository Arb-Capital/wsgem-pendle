// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {DeployPendleWsgemSY} from "./DeployPendleWsgemSY.s.sol";

/// @notice The wstGBP deployment: every parameter of the live Ethereum mainnet instance,
/// pinned in code. Nothing has to be exported to run it — that is the point. Deploy and
/// health-check behaviour is inherited wholesale from {DeployPendleWsgemSY}; only the
/// configuration is fixed here.
///
/// Env vars:
///   SY_OWNER  begin two-step ownership transfer after deploy (optional, and the only
///             configuration this script accepts; the new owner must then call
///             claimOwnership() from its own address). Pin OPS_OWNER below instead to
///             stop passing it by hand.
///
/// WSGEM / EXPECTED_GEM / SY_NAME / SY_SYMBOL are pinned, not read: a value exported for
/// another instance is refused rather than silently ignored. Use the generic
/// {DeployPendleWsgemSY} for any other wsgem.
///
/// Usage:
///   forge script script/DeployPendleWstGbpSY.s.sol --rpc-url mainnet -vvv           (dry run)
///   forge script script/DeployPendleWstGbpSY.s.sol --rpc-url mainnet --broadcast --verify -vvv
///   forge script script/DeployPendleWstGbpSY.s.sol --sig "check(address)" <SY_ADDR> \
///     --rpc-url mainnet -vvv                                    (post-broadcast/health)
///
/// Or through the Makefile, which drives this script by default:
///   make deploy-dry / make deploy / make check SY=0x...
///
/// Manual verification fallback (constructor args are the pinned values):
///   forge verify-contract <ADDR> src/PendleWsgemSY.sol:PendleWsgemSY --chain mainnet \
///     --compiler-version 0.8.28 --num-of-optimizations 1000000 \
///     --constructor-args $(cast abi-encode "constructor(string,string,address)" \
///       "SY Wren Staked tGBP" "SY-wstGBP" 0x57C3571f10767E49C9d7b60feb6c67804783B7aE)
contract DeployPendleWstGbpSY is DeployPendleWsgemSY {
    /// @notice wstGBP ("Wren Staked tGBP") on Ethereum mainnet — the wsgem being wrapped.
    address public constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;

    /// @notice tGBP on Ethereum mainnet — the gem backing wstGBP, cross-checked against
    /// `wstGBP.gem()` before anything is deployed.
    address public constant TGBP = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;

    /// @notice SY ERC20 metadata, mirroring the wrapped token ("Wren Staked tGBP" /
    /// "wstGBP"). Immutable once constructed.
    string public constant SY_NAME = "SY Wren Staked tGBP";
    string public constant SY_SYMBOL = "SY-wstGBP";

    /// @notice Ops multisig to hand the SY's pause/sweep powers to, or address(0) to
    /// leave the deployer as owner and transfer later. Overridden by SY_OWNER.
    address public constant OPS_OWNER = address(0);

    function target() public view override returns (address wsgem, address expectedGem, address owner) {
        _requirePinned("WSGEM", WSTGBP);
        _requirePinned("EXPECTED_GEM", TGBP);
        return (WSTGBP, TGBP, vm.envOr("SY_OWNER", OPS_OWNER));
    }

    function naming() public view override returns (string memory name, string memory symbol) {
        _requirePinned("SY_NAME", SY_NAME);
        _requirePinned("SY_SYMBOL", SY_SYMBOL);
        return (SY_NAME, SY_SYMBOL);
    }
}
