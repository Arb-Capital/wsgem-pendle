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
/// deployment on Ethereum mainnet; override the env vars to deploy for another wsgem
/// instance (e.g. wstCAD).
///
/// Env vars:
///   WSGEM         wsgem token address        (default: wstGBP mainnet)
///   SY_NAME       SY token name              (default: "SY Wren Staked tGBP")
///   SY_SYMBOL     SY token symbol            (default: "SY-wstGBP")
///   EXPECTED_GEM  assert wsgem.gem() matches (default: tGBP mainnet; set for new instances)
///   SY_OWNER      transfer ownership (pause rights) after deploy (optional)
///
/// Usage:
///   forge script script/DeployPendleWsgemSY.s.sol --rpc-url mainnet -vvv            (dry run)
///   forge script script/DeployPendleWsgemSY.s.sol --rpc-url mainnet --broadcast --verify -vvv
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
        string memory name = vm.envOr("SY_NAME", string("SY Wren Staked tGBP"));
        string memory symbol = vm.envOr("SY_SYMBOL", string("SY-wstGBP"));
        address expectedGem = vm.envOr("EXPECTED_GEM", wsgem == WSTGBP ? TGBP : address(0));

        // Pre-deploy sanity: right underlying, oracle alive.
        if (expectedGem != address(0)) {
            require(IWsgem(wsgem).gem() == expectedGem, "wsgem.gem() != EXPECTED_GEM");
        }
        require(IWsgem(wsgem).navprice() > 0, "oracle paused");

        vm.startBroadcast();
        sy = new PendleWsgemSY(name, symbol, wsgem);

        address owner = vm.envOr("SY_OWNER", address(0));
        if (owner != address(0)) {
            sy.transferOwnership(owner, true, false);
        }
        vm.stopBroadcast();

        _sanity(sy, wsgem, owner);
        console.log("PendleWsgemSY deployed:", address(sy));
        console.log("  wsgem:", wsgem);
        console.log("  gem:  ", sy.gem());
    }

    function _sanity(PendleWsgemSY sy, address wsgem, address owner) internal view {
        address gem = IWsgem(wsgem).gem();

        require(sy.decimals() == 18, "decimals");
        require(sy.yieldToken() == wsgem, "yieldToken");
        require(sy.wsgem() == wsgem, "wsgem");
        require(sy.gem() == gem, "gem");

        uint256 nav = IWsgem(wsgem).navprice();
        require(sy.exchangeRate() == nav && nav > 0, "exchangeRate");

        require(sy.previewDeposit(wsgem, 1e18) == 1e18, "previewDeposit wsgem");
        require(sy.previewDeposit(gem, IWsgem(wsgem).mintcost()) == 1e18, "previewDeposit gem");
        require(sy.previewRedeem(wsgem, 1e18) == 1e18, "previewRedeem");

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

        if (owner != address(0)) {
            require(sy.owner() == owner, "owner");
        }
    }
}
