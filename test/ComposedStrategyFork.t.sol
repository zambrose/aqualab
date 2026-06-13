// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { ComposedStrategyBuilder } from "../src/ComposedStrategyBuilder.sol";
import { AquaLabTaker } from "./AquaLabTaker.sol";

/// @title ComposedStrategyFork
/// @notice Fork tests for the composed "sophisticated position": fee + decay layered
///         around an AMM curve, shipped into the LIVE Aqua deployment and swapped
///         with real WETH/USDC transfers.
///
///         Covers:
///           - constant-product + fee + decay: ship + swap, exact fee accounting,
///           - concentrated-liquidity + fee + decay: ship + swap inside a price band,
///           - the two-swap (small → large) "progressive" scenario showing decay
///             worsening the price of a same-direction follow-up trade.
contract ComposedStrategyForkTest is Test {
    // 1e9 = 100% in SwapVM fee bps.
    uint256 internal constant BPS = 1e9;

    address internal constant AQUA_ADDR = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 internal constant FORK_BLOCK = 25_300_000;

    // ~3000 USDC/WETH spot pool.
    uint256 internal constant RESERVE_WETH = 100 ether;
    uint256 internal constant RESERVE_USDC = 300_000 * 1e6;

    // 30 bps (0.30%) LP fee in SwapVM bps (1e9 = 100%).
    uint32 internal constant FEE_BPS = 3_000_000;
    // 1-hour decay window.
    uint16 internal constant DECAY_PERIOD = 3600;

    IAqua internal aqua;
    AquaSwapVMRouter internal router;
    ComposedStrategyBuilder internal builder;
    AquaLabTaker internal taker;

    address internal maker = makeAddr("composedMaker");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

        aqua = IAqua(AQUA_ADDR);
        router = new AquaSwapVMRouter(AQUA_ADDR, WETH, address(this), "SwapVM", "1.0.0");
        builder = new ComposedStrategyBuilder(AQUA_ADDR);
        taker = new AquaLabTaker(router.asView());
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Ship a composed pool (the maker funds reserves and approves Aqua).
    function _shipComposed(ComposedStrategyBuilder.PoolParams memory params)
        internal
        returns (ISwapVM.Order memory order, bytes32 strategyHash)
    {
        order = builder.buildComposedOrder(maker, params);
        bytes32 orderHash = router.hash(order);

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

        assertEq(strategyHash, orderHash, "composed strategyHash must equal router orderHash");
    }

    function _takerData(bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: "",
            to: address(taker),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            preTransferOutCallbackData: "",
            preTransferInCallbackData: "",
            postTransferOutHookData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    /// @dev Pull a WETH amount into the taker and approve the router.
    function _fundTakerWeth(uint256 amount) internal {
        deal(WETH, address(taker), amount);
        taker.approveRouter(WETH, amount);
    }

    /// @dev Constant-product exact-in output AFTER a flat fee on amountIn.
    ///      fee rounds UP (ceilDiv), swap prices the NET input against reserves.
    function _expectedOutWithFee(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint32 feeBps)
        internal
        pure
        returns (uint256)
    {
        uint256 netIn = amountIn - Math.ceilDiv(amountIn * feeBps, BPS);
        return netIn * reserveOut / (reserveIn + netIn);
    }

    function _ccParams(uint64 salt) internal pure returns (ComposedStrategyBuilder.PoolParams memory) {
        return ComposedStrategyBuilder.PoolParams({
            salt: salt,
            feeBps: FEE_BPS,
            decayPeriod: DECAY_PERIOD,
            curve: ComposedStrategyBuilder.Curve.ConstantProduct,
            sqrtPriceMin: 0,
            sqrtPriceMax: 0
        });
    }

    // =====================================================================
    // Constant-product + fee + decay
    // =====================================================================

    /// @notice Ship constant-product + fee + decay and swap WETH→USDC. The output
    ///         must be strictly LESS than the no-fee output by exactly the fee on
    ///         the input (the maker keeps the fee inside the pool).
    function test_Fork_Composed_CC_ShipAndSwap_WithFee() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipComposed(_ccParams(101));

        (uint256 poolWethBefore, uint256 poolUsdcBefore) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        assertEq(poolWethBefore, RESERVE_WETH, "seed WETH");
        assertEq(poolUsdcBefore, RESERVE_USDC, "seed USDC");

        uint256 amountIn = 1 ether;
        _fundTakerWeth(amountIn);

        uint256 noFeeOut = RESERVE_USDC * amountIn / (RESERVE_WETH + amountIn);
        uint256 expectedOut = _expectedOutWithFee(amountIn, RESERVE_WETH, RESERVE_USDC, FEE_BPS);

        uint256 takerUsdcBefore = IERC20(USDC).balanceOf(address(taker));

        (uint256 reportedIn, uint256 reportedOut) =
            taker.swap(order, WETH, USDC, amountIn, _takerData(true));

        assertEq(reportedIn, amountIn, "exact-in consumes full input");
        assertEq(reportedOut, expectedOut, "fee-adjusted x*y=k output matches");
        assertLt(reportedOut, noFeeOut, "fee strictly reduces output vs no-fee");

        // Real ERC-20 movement: taker receives the fee-adjusted USDC.
        assertEq(IERC20(USDC).balanceOf(address(taker)) - takerUsdcBefore, reportedOut, "taker received USDC");

        // The maker keeps the FULL 1 WETH in the pool but only paid out the
        // fee-reduced USDC, so k grows MORE than the no-fee swap would.
        (uint256 poolWethAfter, uint256 poolUsdcAfter) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        assertEq(poolWethAfter, poolWethBefore + amountIn, "pool gained full WETH input");
        assertEq(poolUsdcAfter, poolUsdcBefore - reportedOut, "pool paid fee-reduced USDC");
        assertGe(poolWethAfter * poolUsdcAfter, poolWethBefore * poolUsdcBefore, "k non-decreasing");

        console.log("CC+fee+decay: no-fee out / fee out:", noFeeOut, reportedOut);
    }

    /// @notice TWO-SWAP "progressive" scenario. Two IDENTICAL same-direction trades
    ///         back-to-back: with decay active, the SECOND trade gets a WORSE price
    ///         than the first because the first trade's offset has not yet decayed
    ///         away — the pool's MEV / size protection. The two-swap beat of the demo.
    function test_Fork_Composed_TwoSwap_DecayProgressiveCost() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipComposed(_ccParams(102));

        uint256 amountIn = 5 ether;

        // --- first trade ---
        _fundTakerWeth(amountIn);
        (, uint256 out1) = taker.swap(order, WETH, USDC, amountIn, _takerData(true));

        // --- second, identical trade, in the SAME block (no time elapsed) ---
        _fundTakerWeth(amountIn);
        (, uint256 out2) = taker.swap(order, WETH, USDC, amountIn, _takerData(true));

        // Two effects both push out2 < out1: (a) constant-product reserves moved
        // against the taker after trade 1, and (b) decay added an offset that
        // virtually shrinks balanceOut for trade 2. Either way the follow-up trade
        // is strictly more expensive per unit — the "progressive cost" beat.
        assertLt(out2, out1, "second same-direction trade priced worse (decay + curve)");

        // After the full decay window elapses, the offset is gone: a third trade
        // is priced only off the (now larger-reserve) curve, i.e. it must do
        // strictly BETTER than out2 (which paid both curve move AND decay offset).
        (uint256 wMid, uint256 uMid) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        uint256 curveOnlyOut3 = _expectedOutWithFee(amountIn, wMid, uMid, FEE_BPS);

        vm.warp(block.timestamp + DECAY_PERIOD + 1);
        _fundTakerWeth(amountIn);
        (, uint256 out3) = taker.swap(order, WETH, USDC, amountIn, _takerData(true));

        // With the offset fully decayed, trade 3 prices purely off the curve.
        assertEq(out3, curveOnlyOut3, "after decay window, price is curve-only again");

        console.log("two-swap decay: out1, out2, out3:", out1, out2, out3);
    }

    // =====================================================================
    // Concentrated liquidity + fee + decay
    // =====================================================================

    /// @notice Ship concentrated-liquidity + fee + decay and swap inside the band.
    ///         Concentrated liquidity amplifies depth: for the SAME real reserves
    ///         and same input, a tight band returns MORE output than plain x*y=k
    ///         (virtual reserves are larger), and the spot price stays in [P_min,P_max].
    function test_Fork_Composed_Concentrated_ShipAndSwap() public {
        // P = tokenGt/tokenLt in RAW token units (USDC < WETH ⇒ tokenLt=USDC,
        // tokenGt=WETH). With 100e18 WETH / 300_000e6 USDC the raw ratio is
        //   P = 100e18 / 300_000e6 ≈ 3.33e8,  sqrt(P)·1e18 ≈ 1.8257e22.
        // (The 1e12 decimals gap between WETH(18) and USDC(6) is why sqrt(P) is
        //  ~1e22, NOT ~1e16 — the band is expressed in raw-balance space.)
        // Band: ±5% around that implied spot, so the spot stays inside [min,max].
        uint256 sqrtMin = 17_344_547_654_330_260_259_470; // ~sqrt(P_spot)*0.95 ·1e18
        uint256 sqrtMax = 19_170_289_512_680_813_970_993; // ~sqrt(P_spot)*1.05 ·1e18

        ComposedStrategyBuilder.PoolParams memory params = ComposedStrategyBuilder.PoolParams({
            salt: 201,
            feeBps: FEE_BPS,
            decayPeriod: DECAY_PERIOD,
            curve: ComposedStrategyBuilder.Curve.Concentrated,
            sqrtPriceMin: sqrtMin,
            sqrtPriceMax: sqrtMax
        });

        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipComposed(params);

        uint256 amountIn = 1 ether;
        _fundTakerWeth(amountIn);

        // Plain constant-product (real reserves), fee-adjusted, for comparison.
        uint256 plainOut = _expectedOutWithFee(amountIn, RESERVE_WETH, RESERVE_USDC, FEE_BPS);

        uint256 takerUsdcBefore = IERC20(USDC).balanceOf(address(taker));
        (uint256 reportedIn, uint256 reportedOut) =
            taker.swap(order, WETH, USDC, amountIn, _takerData(true));

        assertEq(reportedIn, amountIn, "exact-in consumes full input");
        assertGt(reportedOut, 0, "non-zero concentrated output");
        assertEq(IERC20(USDC).balanceOf(address(taker)) - takerUsdcBefore, reportedOut, "taker received USDC");

        // Concentrated band amplifies depth → strictly more out than plain x*y=k.
        assertGt(reportedOut, plainOut, "concentrated band deeper than plain x*y=k");

        // Reserves still moved through Aqua, and k of the REAL reserves still grows.
        (uint256 poolWethAfter, uint256 poolUsdcAfter) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        assertEq(poolWethAfter, RESERVE_WETH + amountIn, "pool gained WETH");
        assertEq(poolUsdcAfter, RESERVE_USDC - reportedOut, "pool paid USDC");

        console.log("concentrated vs plain out:", reportedOut, plainOut);
    }
}
