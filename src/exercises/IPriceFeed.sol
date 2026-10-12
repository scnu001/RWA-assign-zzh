// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title NAV oracle interface
/// @notice In this lab the feed carries the fund's NAV per share, not the price of an ETH or
///         a dollar. It is deliberately shaped like Chainlink's AggregatorV3, so swapping in
///         a real feed later is a drop-in change.
/// @dev On real Chainlink feeds decimals() differs from pair to pair. Hardcoding 8 is a
///      simplification this exercise makes to keep the focus on decimal handling.
interface IPriceFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
