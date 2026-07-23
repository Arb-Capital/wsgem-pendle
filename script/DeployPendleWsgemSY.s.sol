// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PendleWsgemSY} from "../src/PendleWsgemSY.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";
import {IStandardizedYield} from "pendle-sy/interfaces/IStandardizedYield.sol";

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}

/// @notice Deploys PendleWsgemSY against a live wsgem token. Defaults target the wstGBP
/// deployment on Ethereum mainnet; for any other wsgem instance (e.g. wstCAD), SY_NAME,
/// SY_SYMBOL, and EXPECTED_GEM must all be set explicitly — there is nothing sensible to
/// default them to, and inheriting the wstGBP branding or skipping the gem check has
/// permanent consequences on an immutable contract.
///
/// Env vars:
///   WSGEM         wsgem token address        (default: wstGBP mainnet)
///   SY_NAME       SY token name              (wstGBP default: "SY Wren Staked tGBP")
///   SY_SYMBOL     SY token symbol            (wstGBP default: "SY-wstGBP")
///   EXPECTED_GEM  assert wsgem.gem() matches (wstGBP default: tGBP mainnet)
///   SY_OWNER      begin two-step ownership transfer after deploy (optional; the new
///                 owner must then call claimOwnership() from its own address)
///
/// Usage:
///   forge script script/DeployPendleWsgemSY.s.sol --rpc-url mainnet -vvv            (dry run)
///   forge script script/DeployPendleWsgemSY.s.sol --rpc-url mainnet --broadcast --verify -vvv
///
/// Post-broadcast: re-run the sanity battery against the mined instance (and any time
/// after — it doubles as a health check: it requires deficit() == 0, an unpaused SY,
/// and no unexpected pending owner). It reads the same WSGEM / EXPECTED_GEM / SY_OWNER
/// env vars (and defaults) as run(), deliberately not the SY under check:
///   forge script script/DeployPendleWsgemSY.s.sol --sig "check(address)" <SY_ADDR> \
///     --rpc-url mainnet -vvv
///
/// Manual verification fallback:
///   forge verify-contract <ADDR> src/PendleWsgemSY.sol:PendleWsgemSY --chain mainnet \
///     --compiler-version 0.8.28 --num-of-optimizations 1000000 \
///     --constructor-args $(cast abi-encode "constructor(string,string,address)" \
///       "<SY_NAME>" "<SY_SYMBOL>" <WSGEM>)
contract DeployPendleWsgemSY is Script {
    // Default instance: wstGBP / tGBP on Ethereum mainnet.
    address constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address constant TGBP = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;

    function run() external returns (PendleWsgemSY sy) {
        address wsgem = vm.envOr("WSGEM", WSTGBP);
        string memory name;
        string memory symbol;
        address expectedGem;
        if (wsgem == WSTGBP) {
            name = vm.envOr("SY_NAME", string("SY Wren Staked tGBP"));
            symbol = vm.envOr("SY_SYMBOL", string("SY-wstGBP"));
            expectedGem = vm.envOr("EXPECTED_GEM", TGBP);
        } else {
            name = vm.envOr("SY_NAME", string(""));
            symbol = vm.envOr("SY_SYMBOL", string(""));
            expectedGem = vm.envOr("EXPECTED_GEM", address(0));
        }
        sy = deploy(wsgem, name, symbol, expectedGem, vm.envOr("SY_OWNER", address(0)));
    }

    function deploy(address wsgem, string memory name, string memory symbol, address expectedGem, address owner)
        public
        returns (PendleWsgemSY sy)
    {
        require(bytes(name).length != 0, "SY_NAME required");
        require(bytes(symbol).length != 0, "SY_SYMBOL required");
        require(expectedGem != address(0), "EXPECTED_GEM required");

        // Pre-deploy sanity: right underlying, oracle alive.
        require(IWsgem(wsgem).gem() == expectedGem, "wsgem.gem() != EXPECTED_GEM");
        require(IWsgem(wsgem).navprice() > 0, "oracle paused");

        vm.startBroadcast();
        sy = new PendleWsgemSY(name, symbol, wsgem);
        if (owner != address(0)) {
            // Two-step on purpose: a mistyped-but-valid SY_OWNER cannot irrevocably
            // strand pause rights; the transfer completes only when the new owner
            // proves liveness by calling claimOwnership() itself.
            sy.transferOwnership(owner, false, false);
        }
        vm.stopBroadcast();

        _sanity(sy, wsgem, owner);
        console.log("PendleWsgemSY deployed:", address(sy));
        console.log("  name:  ", sy.name());
        console.log("  symbol:", sy.symbol());
        console.log("  wsgem: ", wsgem);
        console.log("  gem:   ", sy.gem());
        if (owner != address(0)) {
            console.log("  ownership PENDING; claimOwnership() must be called from:", owner);
        }
    }

    /// @notice Re-runs the full sanity battery against a live SY instance. The
    /// expected wsgem and gem come from the environment (same vars and defaults as
    /// run()), NOT from the SY under check — reading them from the target would
    /// reduce the battery to self-consistency and let any healthy SY deployment
    /// pass, including one bound to the wrong wsgem.
    function check(address syAddr) external view {
        address wsgem = vm.envOr("WSGEM", WSTGBP);
        address expectedGem = vm.envOr("EXPECTED_GEM", wsgem == WSTGBP ? TGBP : address(0));
        check(syAddr, wsgem, expectedGem, vm.envOr("SY_OWNER", address(0)));
    }

    function check(address syAddr, address wsgem, address expectedGem, address owner) public view {
        require(expectedGem != address(0), "EXPECTED_GEM required");
        require(IWsgem(wsgem).gem() == expectedGem, "wsgem.gem() != EXPECTED_GEM");
        _sanity(PendleWsgemSY(payable(syAddr)), wsgem, owner);
    }

    function _sanity(PendleWsgemSY sy, address wsgem, address owner) internal view {
        address gem = IWsgem(wsgem).gem();

        require(sy.decimals() == 18, "decimals");
        require(sy.yieldToken() == wsgem, "yieldToken");
        require(sy.wsgem() == wsgem, "wsgem");
        require(sy.gem() == gem, "gem");
        require(sy.deficit() == 0, "deficit != 0");
        // A paused SY has deposits, redemptions, and share transfers frozen even
        // though every preview below still answers — that is not healthy.
        require(!sy.paused(), "SY paused");

        uint256 nav = IWsgem(wsgem).navprice();
        require(sy.exchangeRate() == nav && nav > 0, "exchangeRate");

        require(sy.previewDeposit(wsgem, 1e18) == 1e18, "previewDeposit wsgem");
        if (IWsgem(wsgem).mintable()) {
            require(sy.previewDeposit(gem, IWsgem(wsgem).mintcost()) == 1e18, "previewDeposit gem");
        } else {
            console.log("WARN: wsgem mint window closed; gem-route preview check skipped");
        }

        // previewRedeem is balance-aware: exact up to the held wsgem (zero on a fresh
        // deploy), SYInsolvent past it — with the shortfall as the error argument.
        uint256 held = IWsgem(wsgem).balanceOf(address(sy));
        if (held > 0) {
            require(sy.previewRedeem(wsgem, held) == held, "previewRedeem held");
        }
        try sy.previewRedeem(wsgem, held + 1e18) returns (uint256) {
            revert("previewRedeem must revert past balance");
        } catch (bytes memory err) {
            require(
                keccak256(err) == keccak256(abi.encodeWithSelector(PendleWsgemSY.SYInsolvent.selector, 1e18)),
                "previewRedeem tail error"
            );
        }

        require(sy.isValidTokenIn(wsgem) && sy.isValidTokenIn(gem), "tokensIn");
        require(sy.isValidTokenOut(wsgem) && !sy.isValidTokenOut(gem), "tokensOut");
        require(sy.getTokensIn().length == 2 && sy.getTokensOut().length == 1, "token lists");

        (IStandardizedYield.AssetType assetType, address assetAddress, uint8 assetDecimals) = sy.assetInfo();
        require(
            assetType == IStandardizedYield.AssetType.TOKEN && assetAddress == gem
                && assetDecimals == IERC20MetadataLike(gem).decimals(),
            "assetInfo"
        );

        require(IWsgem(wsgem).canPass(address(sy)), "SY fails compliance screen");

        if (owner != address(0) && sy.owner() != owner) {
            // Mid-transfer toward the declared owner: exactly that address may be
            // parked in the pending slot.
            require(sy.pendingOwner() == owner, "owner");
        } else {
            // In every other state — expected owner active, or no expected owner
            // declared at all — the pending slot must be empty: a parked transfer to
            // anyone is a takeover vector the pending owner can complete unilaterally.
            require(sy.pendingOwner() == address(0), "unexpected pending owner");
        }
    }
}
