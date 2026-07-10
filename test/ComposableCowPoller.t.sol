// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {BaseComposableCoWTest} from "./ComposableCoW.base.t.sol";

import {ComposableCowPoller} from "../src/types/ComposableCowPoller.sol";

/// @title ComposableCowPoller unit tests
/// @notice Base scaffolding for the poller. Feature-specific tests (register / revoke / topUp) are
///         added in follow-up PRs.
contract ComposableCowPollerTest is BaseComposableCoWTest {
    ComposableCowPoller poller;

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        poller = new ComposableCowPoller();
    }

    function test_deployment() public {
        assertTrue(address(poller) != address(0), "poller deployed");
    }
}
