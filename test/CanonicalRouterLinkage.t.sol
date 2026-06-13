// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { AquaSwapVMRouter } from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";

/// @dev Minimal view into the canonical deployed router. We only need `AQUA()`.
interface IRouterAqua {
    function AQUA() external view returns (address);
}

/// @title CanonicalRouterLinkage
/// @notice On-chain proof, on the mainnet fork, that AquaLab engages the LIVE
///         1inch deployment — without pretending we can execute our pinned
///         program bytes on the canonical router.
///
/// ## The hybrid model (read docs/notes.md §11 for the full derivation)
///
/// The canonical SwapVM router deployed at
/// `0x8fDD04Dbf6111437B44bbca99C28882434e0958f` is a NEWER, UNPUBLISHED build:
/// 0.0.6 is the only release tag and `main`'s AquaOpcodes table is byte-identical
/// to 0.0.6 (no `_progressiveFeeInXD` in the Aqua table — it has reserved
/// `_notInstruction` slots that the deployed build filled). So our 0.0.6 program
/// bytes CANNOT execute on the deployed router (confirmed by reverts), and we do
/// NOT try to. Instead AquaLab:
///   - executes swaps on a FRESH-DEPLOYED AquaSwapVMRouter built from the pinned,
///     reproducible swap-vm 0.0.6 source (the stateless execution engine), AND
///   - ships its liquidity into the SAME live Aqua singleton the canonical router
///     uses (`0x499943E7…6d31`) — so the liquidity layer is already the real
///     canonical Aqua; only the stateless engine is self-deployed.
///
/// This test asserts exactly those linkage facts on the fork.
contract CanonicalRouterLinkageTest is Test {
    // The canonical SwapVM router deployed on mainnet (newer unpublished build).
    address internal constant CANONICAL_ROUTER = 0x8fDD04Dbf6111437B44bbca99C28882434e0958f;

    // The live Aqua singleton (same address multi-chain). Our strategies ship here.
    address internal constant AQUA_ADDR = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;

    // Real mainnet WETH (router constructor arg for our fresh deploy).
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal constant FORK_BLOCK = 25_300_000;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
    }

    /// @notice Prove engagement with the live deployment, and honestly surface the
    ///         dev-preview version skew between the deployed router and our pinned
    ///         0.0.6 self-deploy.
    function test_Fork_CanonicalRouterLinkage() public {
        // (1) The canonical router is real on this fork: it has nonzero code.
        uint256 canonicalCodeSize;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            canonicalCodeSize := extcodesize(CANONICAL_ROUTER)
        }
        assertGt(canonicalCodeSize, 0, "canonical router must have code on the fork");

        // (2) The canonical router uses the SAME live Aqua we ship liquidity into.
        //     This is the load-bearing linkage: our liquidity layer IS the real
        //     canonical Aqua; only the stateless execution engine differs.
        address canonicalAqua = IRouterAqua(CANONICAL_ROUTER).AQUA();
        assertEq(canonicalAqua, AQUA_ADDR, "canonical router AQUA() must equal our Aqua constant");

        // (3) Demonstrate the version skew honestly. Deploy a fresh 0.0.6 router
        //     (the exact build our strategies execute against) and prove its code
        //     differs from the deployed router — i.e. they are different builds.
        //     The deployed router is a newer unpublished build; we pin 0.0.6 for
        //     reproducibility and self-deploy the stateless engine, while using the
        //     real live Aqua liquidity layer (asserted above).
        AquaSwapVMRouter freshRouter =
            new AquaSwapVMRouter(AQUA_ADDR, WETH, address(this), "SwapVM", "1.0.0");
        uint256 freshCodeSize = address(freshRouter).code.length;

        assertGt(freshCodeSize, 0, "fresh 0.0.6 router must have code");
        assertTrue(
            canonicalCodeSize != freshCodeSize,
            "deployed router and our 0.0.6 self-deploy must be different builds (version skew)"
        );

        // Sanity: the fresh 0.0.6 router also points at the same live Aqua, so the
        // ONLY difference between the two execution surfaces is the build, not the
        // liquidity layer.
        assertEq(address(freshRouter.AQUA()), AQUA_ADDR, "fresh router AQUA() must also equal our Aqua constant");

        console.log("canonical deployed router codesize:", canonicalCodeSize);
        console.log("fresh 0.0.6 self-deploy  codesize:", freshCodeSize);
        console.log("both AQUA() ==", canonicalAqua);
    }
}
