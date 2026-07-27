// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import "pendle-sy/core/StandardizedYield/v2/SYBaseV2.sol";
import {IWsgem} from "./interfaces/IWsgem.sol";

/// @notice Pendle Standardized Yield (EIP-5115) wrapper for a wsgem token — a wrapped
/// staked currency token. One deployment serves one wsgem instance.
///
/// A wsgem is a non-rebasing, NAV-accruing wrapper of an underlying currency token (the
/// "gem"): its gem value is an oracle-set NAV rather than an on-chain balance
/// ratio. `navprice()` is quoted in gem native units per whole (1e18) wsgem, so the
/// contract is agnostic to the gem's decimals. 1 SY share == 1 wsgem, `exchangeRate()`
/// is `navprice()`, and the Pendle asset is the gem.
///
/// Deposits: wsgem 1:1, or gem (wrapped via `wsgem.mint()`, fee = bpsin).
/// Redemptions: wsgem 1:1 only. The gem is intentionally not a tokenOut —
/// `wsgem.redeem()` carries a bpsout fee, a one-wsgem minimum, and a governable
/// cooldown that can make redemption non-atomic; holders unwrap via the wsgem
/// contract directly.
///
/// Trust notes: the NAV oracle is permissioned and non-monotonic (it can be poked down
/// or paused to 0); every wsgem transfer screens all involved addresses — including
/// this contract — against the gem's ban list; and wsgem issuers can forcibly burn
/// wsgem from ANY holder (`smelt(address,uint256)`), including this SY. A smelt against
/// the SY leaves shares outstanding with less than 1 wsgem of backing each; `deficit()`
/// surfaces that state for monitoring, and deposits fail closed while it persists
/// (redemptions stay live, first-come, and the owner can `pause()` to intervene).
/// The owner's only other privilege is `sweep()`, which recovers stray assets but can
/// never touch the wsgem backing.
contract PendleWsgemSY is SYBaseV2 {
    address public immutable wsgem;
    address public immutable gem;

    /// @notice The SY's wsgem balance cannot cover the operation: deposits while
    /// outstanding shares exceed backing, or redemption quotes beyond the held balance.
    /// Only reachable after a privileged burn of the SY's wsgem. `deficit` is the wsgem
    /// shortfall for the operation.
    error SYInsolvent(uint256 deficit);

    /// @notice The wsgem backing can never be swept.
    error SweepBackingToken();

    event Sweep(address indexed token, address indexed receiver, uint256 amount);

    constructor(string memory _name, string memory _symbol, address _wsgem) SYBaseV2(_name, _symbol, _wsgem) {
        wsgem = _wsgem;
        gem = IWsgem(_wsgem).gem();
        _safeApproveInf(gem, _wsgem);
    }

    /*///////////////////////////////////////////////////////////////
                    DEPOSIT/REDEEM USING BASE TOKENS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address tokenIn, uint256 amountDeposited)
        internal
        virtual
        override
        returns (uint256 amountSharesOut)
    {
        // Refuse to dilute new depositors into a backing hole (only reachable via a
        // privileged smelt of the SY's wsgem). Each branch orders its checks exactly
        // as _previewDeposit does, so preview and execution revert identically.
        if (tokenIn == wsgem) {
            amountSharesOut = amountDeposited;
            // The deposited wsgem is already in the balance, so full backing means
            // balance >= existing shares + new shares — the same condition (and the
            // same reported deficit) as deficit() in the pre-deposit state.
            uint256 backed = totalSupply() + amountSharesOut;
            uint256 bal = IWsgem(wsgem).balanceOf(address(this));
            if (bal < backed) revert SYInsolvent(backed - bal);
        } else {
            // Gem transfers don't move the wsgem balance, so deficit() still reads the
            // pre-deposit state here. Check it BEFORE minting so that with a deficit
            // and a closed/paused/capped market both preview and execution surface
            // SYInsolvent, not the market error.
            uint256 shortfall = deficit();
            if (shortfall != 0) revert SYInsolvent(shortfall);
            // wsgem.mint() pulls the gem (already in this contract) and returns the
            // exact amount of wsgem minted; neither token has transfer hooks. Solvent
            // before + minted wsgem == new shares -> still solvent after.
            amountSharesOut = IWsgem(wsgem).mint(amountDeposited);
        }
    }

    function _redeem(
        address receiver,
        address,
        /*tokenOut*/
        uint256 amountSharesToRedeem
    )
        internal
        virtual
        override
        returns (uint256 amountTokenOut)
    {
        // Shares are already burned by the base at this point but the wsgem balance is
        // untouched, so the same balance check as _previewRedeem applies. The transfer
        // below would revert on its own past the balance; checking first makes the
        // insolvent tail revert with the same SYInsolvent the preview quotes.
        uint256 bal = IWsgem(wsgem).balanceOf(address(this));
        if (amountSharesToRedeem > bal) revert SYInsolvent(amountSharesToRedeem - bal);
        amountTokenOut = amountSharesToRedeem;
        _transferOut(wsgem, receiver, amountTokenOut);
    }

    /*///////////////////////////////////////////////////////////////
                               EXCHANGE-RATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Gem native units per whole SY share (`assetAmount = syAmount * rate / 1e18`).
    /// Reverts while the NAV oracle is paused: a raw 0 would price the SY as worthless in
    /// downstream quoting, whereas reverting freezes market operations for exactly the
    /// window in which the wsgem's own mint/redeem is frozen. SY -> wsgem redemption
    /// never calls this and stays live during a pause.
    function exchangeRate() public view virtual override returns (uint256 res) {
        res = IWsgem(wsgem).navprice();
        if (res == 0) revert IWsgem.InvalidPrice();
    }

    /*///////////////////////////////////////////////////////////////
                MISC FUNCTIONS FOR METADATA
    //////////////////////////////////////////////////////////////*/

    /// @dev Replicates wsgem.mint() math and revert conditions in execution order,
    /// with identical error selectors, so previews match deposits for every reachable
    /// market state. Per-address compliance checks are deliberately not replicated:
    /// previews are caller-independent.
    function _previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        internal
        view
        override
        returns (uint256 amountSharesOut)
    {
        uint256 shortfall = deficit();
        if (shortfall != 0) revert SYInsolvent(shortfall);

        if (tokenIn == wsgem) return amountTokenToDeposit;

        IWsgem w = IWsgem(wsgem);
        if (!w.mintable()) revert IWsgem.MarketClosed();
        // mintcost() is 0 when the oracle is paused; check price first to mirror
        // wsgem.mint()'s InvalidPrice rather than hitting a division by zero below.
        if (w.navprice() == 0) revert IWsgem.InvalidPrice();
        uint256 unit = w.mintcost();
        if (amountTokenToDeposit < unit) revert IWsgem.DustThreshold(unit);
        amountSharesOut = (amountTokenToDeposit * 1e18) / unit;
        if (w.totalSupply() + amountSharesOut > w.capacity()) revert IWsgem.ExceedsCap();
    }

    function _previewRedeem(
        address,
        /*tokenOut*/
        uint256 amountSharesToRedeem
    )
        internal
        view
        override
        returns (uint256 amountTokenOut)
    {
        // Quote only what execution can deliver: after a privileged smelt the SY can
        // hold fewer wsgem than shares, and redeeming past the balance reverts — so
        // the preview reverts too instead of overquoting the insolvent tail. While
        // solvent the balance covers every outstanding share, so a reverting quote
        // exceeds total supply and corresponds to no redemption anyone could execute.
        uint256 bal = IWsgem(wsgem).balanceOf(address(this));
        if (amountSharesToRedeem > bal) revert SYInsolvent(amountSharesToRedeem - bal);
        amountTokenOut = amountSharesToRedeem;
    }

    function getTokensIn() public view virtual override returns (address[] memory res) {
        res = new address[](2);
        res[0] = wsgem;
        res[1] = gem;
    }

    function getTokensOut() public view virtual override returns (address[] memory res) {
        res = new address[](1);
        res[0] = wsgem;
    }

    function isValidTokenIn(address token) public view virtual override returns (bool) {
        return token == wsgem || token == gem;
    }

    function isValidTokenOut(address token) public view virtual override returns (bool) {
        return token == wsgem;
    }

    function assetInfo() external view returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.TOKEN, gem, IERC20Metadata(gem).decimals());
    }

    /*///////////////////////////////////////////////////////////////
                                 SWEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice Recover assets the SY could otherwise never move: ETH (the base
    /// contract is payable) and tokens transferred here directly instead of deposited.
    /// The wsgem is excluded entirely — backing, and any donated surplus (which is how
    /// a post-smelt deficit is remediated), stays untouchable, so no owner action can
    /// reduce what redemptions draw on. Works while paused: sweeping moves no shares.
    /// @param token ERC20 to sweep, or address(0) for ETH. The full balance is sent.
    function sweep(address token, address receiver) external onlyOwner nonReentrant {
        if (token == wsgem) revert SweepBackingToken();
        uint256 amount = _selfBalance(token);
        _transferOut(token, receiver, amount);
        emit Sweep(token, receiver, amount);
    }

    /*///////////////////////////////////////////////////////////////
                               SOLVENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Shares outstanding beyond the SY's wsgem balance. Non-zero only after a
    /// privileged smelt has burned wsgem from the SY; while non-zero, deposits revert
    /// `SYInsolvent` and redemptions are effectively first-come. Intended for
    /// monitoring/alerting.
    function deficit() public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 bal = IWsgem(wsgem).balanceOf(address(this));
        return bal < supply ? supply - bal : 0;
    }
}
