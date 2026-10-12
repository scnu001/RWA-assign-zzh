// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceFeed} from "./IPriceFeed.sol";

/// @title A NAV feed you can move by hand
/// @notice Local testing only. The number carries 8 decimals and means "one share is worth
///         this many USDC": 1.00e8 is par, 1.0002e8 is par plus a little accrued interest.
///         The vault only ever writes to it through `attest`, which is role-gated — but the
///         value here is still just something an off-chain reporter types in.
contract MockPriceFeed is IPriceFeed {
    int256 public answer;

    event PriceSet(int256 answer);

    constructor(int256 initialAnswer) {
        answer = initialAnswer;
    }

    function setPrice(int256 newAnswer) external {
        answer = newAnswer;
        emit PriceSet(newAnswer);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer_,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}
