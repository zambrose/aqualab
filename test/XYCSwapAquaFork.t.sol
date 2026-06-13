// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { XYCStrategyBuilder } from "../src/XYCStrategyBuilder.sol";
import { AquaLabTaker } from "./AquaLabTaker.sol";

/// @title XYCSwapAquaFork
/// @notice The AquaLab "happy path": ship a stock XYCSwap (x*y=k) SwapVM strategy
///         into the LIVE Aqua deployment on a mainnet fork and execute a real
///         WETH/USDC swap through the AquaSwapVMRouter, asserting visible ERC-20
///         balance changes on both maker and taker.
///
/// Flow (the canonical SwapVM + Aqua-backed sequence):
///   1. Maker funds a WETH/USDC pool by approving Aqua and calling
///      `aqua.ship(router, abi.encode(order), tokens, amounts)`. The returned
///      strategyHash MUST equal `router.hash(order)` — this is the binding that
///      lets the router source/settle the pool's reserves through Aqua.
///   2. Taker holds tokenIn, approves the router, and calls `router.swap(...)`.
///      With `useAquaInsteadOfSignature` (maker side) + `useTransferFromAndAquaPush`
///      (taker side), the router:
///        - reads reserves via AQUA.safeBalances,
///        - runs the program (the `_xycSwapXD` opcode prices the trade),
///        - pulls tokenOut from the maker's Aqua balance to the taker,
///        - transferFroms tokenIn from the taker and AQUA.push-es it to the maker.
///   3. We assert real balances moved and that the pool's k did not decrease,
///      then verify `aqua.safeBalances` reflects the new reserves and that
///      `aqua.dock` unwinds the position.
contract XYCSwapAquaForkTest is Test {
    // Live Aqua deployment (same address multi-chain). Has bytecode on the fork.
    address internal constant AQUA_ADDR = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;

    // Real mainnet tokens.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Pinned fork block: a few thousand blocks back from head (~25,306,200) for
    // determinism and shared cache reuse across agents.
    uint256 internal constant FORK_BLOCK = 25_300_000;

    // Pool reserves: 100 WETH and 300,000 USDC (~3000 USDC/WETH spot).
    uint256 internal constant RESERVE_WETH = 100 ether;
    uint256 internal constant RESERVE_USDC = 300_000 * 1e6;

    IAqua internal aqua;
    AquaSwapVMRouter internal router;
    XYCStrategyBuilder internal builder;
    AquaLabTaker internal taker;

    address internal maker = makeAddr("maker");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

        aqua = IAqua(AQUA_ADDR);
        // The router is deployed by us in-test; it points at the live Aqua and
        // real WETH. `address(this)` is just the fund-rescue owner.
        router = new AquaSwapVMRouter(AQUA_ADDR, WETH, address(this), "SwapVM", "1.0.0");
        builder = new XYCStrategyBuilder(AQUA_ADDR);
        taker = new AquaLabTaker(router.asView());
    }

    /// @dev Maker ships a WETH/USDC XYCSwap pool into Aqua, returns the order + hash.
    function _shipPool(uint64 salt) internal returns (ISwapVM.Order memory order, bytes32 strategyHash) {
        order = builder.buildOrder(maker, salt);
        bytes32 orderHash = router.hash(order);

        // Fund the maker with the reserves and approve Aqua to custody them.
        deal(WETH, maker, RESERVE_WETH);
        deal(USDC, maker, RESERVE_USDC);
        vm.startPrank(maker);
        IERC20(WETH).approve(AQUA_ADDR, type(uint256).max);
        IERC20(USDC).approve(AQUA_ADDR, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = RESERVE_WETH;
        amounts[1] = RESERVE_USDC;

        strategyHash = aqua.ship(address(router), abi.encode(order), tokens, amounts);
        vm.stopPrank();

        // The Aqua strategy hash must equal the router's order hash, otherwise
        // the router cannot find the reserves at swap time.
        assertEq(strategyHash, orderHash, "Aqua strategyHash must equal router orderHash");
    }

    /// @dev Build taker traits: exact-in, Aqua transferFrom+push mode, output to taker.
    function _takerData(bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: "", // no min-out constraint for the happy path
            to: address(taker),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    // ----------------------------------------------------------------------
    // The headline test: a real, transfer-visible WETH -> USDC swap.
    // ----------------------------------------------------------------------
    function test_Fork_ShipAndSwap_WETH_for_USDC() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipPool(1);

        // Reserves are now custodied/tracked by Aqua for this strategy.
        (uint256 poolWethBefore, uint256 poolUsdcBefore) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        assertEq(poolWethBefore, RESERVE_WETH, "pool seeded with WETH");
        assertEq(poolUsdcBefore, RESERVE_USDC, "pool seeded with USDC");

        // Taker wants to sell 1 WETH for USDC.
        uint256 amountIn = 1 ether;
        deal(WETH, address(taker), amountIn);
        taker.approveRouter(WETH, amountIn);

        uint256 takerWethBefore = IERC20(WETH).balanceOf(address(taker));
        uint256 takerUsdcBefore = IERC20(USDC).balanceOf(address(taker));
        uint256 makerWethWalletBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerUsdcWalletBefore = IERC20(USDC).balanceOf(maker);

        // Expected output from x*y=k (no fee in the minimal strategy):
        // out = reserveOut * amountIn / (reserveIn + amountIn)
        uint256 expectedOut = RESERVE_USDC * amountIn / (RESERVE_WETH + amountIn);

        // quote() is the static preview of swap(). With IDENTICAL taker data it
        // MUST return exactly what the real swap consumes/produces — otherwise a
        // taker's pre-trade quote could differ from execution. Assert that
        // round-trip equality before doing the real swap.
        bytes memory takerData = _takerData(true);
        (uint256 quotedIn, uint256 quotedOut) = taker.quote(order, WETH, USDC, amountIn, takerData);

        (uint256 reportedIn, uint256 reportedOut) =
            taker.swap(order, WETH, USDC, amountIn, takerData);

        // --- quote == swap round-trip ---
        assertEq(quotedIn, reportedIn, "quote amountIn must equal swap amountIn");
        assertEq(quotedOut, reportedOut, "quote amountOut must equal swap amountOut");

        // --- amount accounting ---
        assertEq(reportedIn, amountIn, "exact-in: amountIn consumed");
        assertEq(reportedOut, expectedOut, "x*y=k output matches");
        assertGt(reportedOut, 0, "non-zero output");

        // --- taker ERC-20 balances actually moved ---
        assertEq(takerWethBefore - IERC20(WETH).balanceOf(address(taker)), amountIn, "taker paid 1 WETH");
        assertEq(IERC20(USDC).balanceOf(address(taker)) - takerUsdcBefore, reportedOut, "taker received USDC");

        // --- maker's RAW WALLET tokens move (Aqua is non-custodial) ---
        // Aqua tracks balances as on-demand allowances against the maker's own
        // wallet rather than escrowing tokens in the Aqua contract. So the
        // taker's WETH is pushed straight into the maker's wallet (+1 WETH), and
        // the USDC paid out is pulled straight from the maker's wallet (-out).
        assertEq(IERC20(WETH).balanceOf(maker) - makerWethWalletBefore, amountIn, "maker wallet gained WETH");
        assertEq(makerUsdcWalletBefore - IERC20(USDC).balanceOf(maker), reportedOut, "maker wallet paid USDC");

        // --- pool reserves updated inside Aqua ---
        (uint256 poolWethAfter, uint256 poolUsdcAfter) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        assertEq(poolWethAfter, poolWethBefore + amountIn, "pool gained WETH");
        assertEq(poolUsdcAfter, poolUsdcBefore - reportedOut, "pool lost USDC");

        // --- constant-product invariant never decreases ---
        assertGe(poolWethAfter * poolUsdcAfter, poolWethBefore * poolUsdcBefore, "k must not decrease");

        console.log("Swapped 1 WETH for USDC (6dp):", reportedOut);
    }

    // ----------------------------------------------------------------------
    // The reverse direction, proving bidirectionality through the same pool.
    // ----------------------------------------------------------------------
    function test_Fork_Swap_USDC_for_WETH() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipPool(2);

        uint256 amountIn = 3_000 * 1e6; // sell 3000 USDC
        deal(USDC, address(taker), amountIn);
        taker.approveRouter(USDC, amountIn);

        uint256 takerWethBefore = IERC20(WETH).balanceOf(address(taker));
        uint256 expectedOut = RESERVE_WETH * amountIn / (RESERVE_USDC + amountIn);

        (uint256 reportedIn, uint256 reportedOut) =
            taker.swap(order, USDC, WETH, amountIn, _takerData(true));

        assertEq(reportedIn, amountIn, "amountIn consumed");
        assertEq(reportedOut, expectedOut, "x*y=k output matches");
        assertEq(IERC20(WETH).balanceOf(address(taker)) - takerWethBefore, reportedOut, "taker received WETH");

        (uint256 poolWethAfter, uint256 poolUsdcAfter) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        assertEq(poolUsdcAfter, RESERVE_USDC + amountIn, "pool gained USDC");
        assertEq(poolWethAfter, RESERVE_WETH - reportedOut, "pool lost WETH");
    }

    // ----------------------------------------------------------------------
    // safeBalances reflects the active position; dock unwinds it.
    // ----------------------------------------------------------------------
    function test_Fork_SafeBalances_And_Dock() public {
        (, bytes32 strategyHash) = _shipPool(3);

        // safeBalances returns the live reserves of the active strategy.
        (uint256 w, uint256 u) = aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        assertEq(w, RESERVE_WETH, "safeBalances WETH");
        assertEq(u, RESERVE_USDC, "safeBalances USDC");

        // Dock the strategy: clears all token balances, deactivating the pool.
        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        vm.prank(maker);
        aqua.dock(address(router), strategyHash, tokens);

        // rawBalances are now zero for the docked strategy...
        (uint256 rawW,) = aqua.rawBalances(maker, address(router), strategyHash, WETH);
        (uint256 rawU,) = aqua.rawBalances(maker, address(router), strategyHash, USDC);
        assertEq(rawW, 0, "docked: raw WETH cleared");
        assertEq(rawU, 0, "docked: raw USDC cleared");

        // ...and safeBalances reverts because the strategy is no longer active.
        vm.expectRevert();
        aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
    }
}
