// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Minimal interface for a wsgem token — a wrapped staked currency such as
/// wstGBP or wstCAD, backed by an underlying currency token (the "gem").
/// Errors are mirrored from the wsgem implementation so that preview reverts carry
/// selectors identical to the reverts of the real wsgem.mint() path.
interface IWsgem {
    error MarketClosed();
    error InvalidPrice();
    error ExceedsCap();
    error DustThreshold(uint256 min);
    error NotAuthorized(address usr);

    /// @notice Deposit `amt` of gem, receive wsgem at mintcost(). Returns the exact minted amount.
    function mint(uint256 amt) external returns (uint256 _out);

    function gem() external view returns (address);
    function navprice() external view returns (uint256);
    function mintcost() external view returns (uint256);
    function burncost() external view returns (uint256);
    function mintable() external view returns (bool);
    function burnable() external view returns (bool);
    function capacity() external view returns (uint256);
    function cooldown() external view returns (uint256);
    function canPass(address usr) external view returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address usr) external view returns (uint256);
}
