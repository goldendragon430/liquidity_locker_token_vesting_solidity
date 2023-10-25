// SPDX-License-Identifier: UNLICENSED
// ALL RIGHTS RESERVED
// Unicrypt by SDDTech reserves all rights on this code. You may NOT copy these contracts.

pragma solidity ^0.8.0;

import "./FullMath.sol";

library VestingMathLibrary {
    // gets the withdrawable amount from a lock
    function getWithdrawableAmount(
        uint256 startEmission,
        uint256 endEmission,
        uint256 amount,
        uint256 timeStamp
    ) internal pure returns (uint256) {
        // Lock type 1 logic block (Normal Unlock on due date)
        if (startEmission == 0 || startEmission == endEmission) {
            return endEmission < timeStamp ? amount : 0;
        }
        // Lock type 2 logic block (Linear scaling lock)
        uint256 timeClamp = timeStamp;
        if (timeClamp > endEmission) {
            timeClamp = endEmission;
        }
        if (timeClamp < startEmission) {
            timeClamp = startEmission;
        }
        uint256 elapsed = timeClamp - startEmission;
        uint256 fullPeriod = endEmission - startEmission;
        return FullMath.mulDiv(amount, elapsed, fullPeriod); // fullPeriod cannot equal zero due to earlier checks and restraints when locking tokens (startEmission < endEmission)
    }
}
