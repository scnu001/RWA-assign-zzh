// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {TBillVault} from "../src/TBillVault.sol";
import {MockTBillCustodian} from "../src/exercises/MockTBillCustodian.sol";

/// @notice Ex3 on the command line: post a NAV the custodian cannot possibly back, then put
///         the two numbers side by side for the screenshot.
///
/// @dev Run it against the chain you already deployed and subscribed on. Export the addresses
///      `make deploy-anvil` printed, then:
///
///        export VAULT=... CUSTODIAN=...
///        forge script script/BreakIt.s.sol:BreakIt --rpc-url $RPC --broadcast
///
///      FAKE_NAV is the NAV the reporter is about to claim, in 8 decimals. The default, 2e8,
///      says "one share is worth two dollars" when nothing at the custodian has changed.
contract BreakIt is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        TBillVault vault = TBillVault(vm.envAddress("VAULT"));
        MockTBillCustodian custodian = MockTBillCustodian(vm.envAddress("CUSTODIAN"));
        int256 fakeNav = int256(vm.envOr("FAKE_NAV", uint256(2e8)));

        console.log("");
        console.log("--- before the reporter opens their mouth ---");
        _report(vault, custodian);

        vm.startBroadcast(pk);
        vault.attest(fakeNav);
        vm.stopBroadcast();

        console.log("");
        console.log("--- after the attestation ---");
        _report(vault, custodian);

        console.log("");
        console.log("The first number is what the chain now believes the fund is worth.");
        console.log("The second is what the custodian says is actually there.");
        console.log("Nothing was hacked. A number was typed in. That gap is plank (b) failing.");
        console.log("");
    }

    function _report(TBillVault vault, MockTBillCustodian custodian) internal view {
        console.log("NAV per share (8dp)     :", vault.navPerShare());
        console.log("totalClaimValue (6dp)   :", vault.totalClaimValue());
        console.log("custodian realHoldings  :", custodian.realHoldings());
        console.log("vault reserveBalance    :", vault.reserveBalance());
    }
}
