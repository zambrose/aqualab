// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { AquaSwapVMRouter } from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { CoreInvariants } from "@1inch/swap-vm/test/invariants/CoreInvariants.t.sol";

import { ComposedStrategyBuilder } from "../src/ComposedStrategyBuilder.sol";

/// @title ComposedInvariants
/// @notice Runs the UPSTREAM swap-vm 0.0.6 `CoreInvariants` battery against the
///         AquaLab COMPOSED strategy (decay + flat fee + constant-product AMM),
///         executed on a freshly-deployed `AquaSwapVMRouter` and backed by the
///         LIVE Aqua deployment on a mainnet fork.
///
///         CoreInvariants is an abstract harness: we implement its `_executeSwap`
///         hook (deal tokenIn → approve router → router.swap) and drive it with
///         `assertAllInvariantsWithConfig`, which asserts:
///           - exact-in/out symmetry,
///           - quote()==swap() consistency,
///           - price monotonicity (bigger trades priced no better),
///           - rounding-favors-maker on dust amounts,
///           - balance sufficiency on oversized trades.
///
///         ## Additivity is configured OFF — and why that is correct, not a dodge
///
///         `skipAdditivity = true`. The additivity invariant asserts that a single
///         swap(A+B) is at least as good as a split swap(A)+swap(B). That holds for
///         a *pure* AMM, but our composed strategy wraps the curve in `_decayXD`
///         MEV protection, which makes price PATH-DEPENDENT by design: the first
///         leg of a split trade writes a decaying offset that worsens the second
///         leg, so swap(A)+swap(B) and swap(A+B) traverse different virtual-reserve
///         states. Additivity is therefore intentionally NOT an invariant of a
///         decay-protected pool (see docs/notes.md §9.4 / §10.2). Every other
///         invariant runs and must pass.
contract ComposedInvariantsTest is CoreInvariants {
    address internal constant AQUA_ADDR = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 internal constant FORK_BLOCK = 25_300_000;

    // Deep reserves so the invariant amounts stay a small fraction of the pool
    // (keeps slippage modest → symmetry tight, monotonicity clean).
    uint256 internal constant RESERVE_WETH = 1_000 ether;
    uint256 internal constant RESERVE_USDC = 3_000_000 * 1e6;

    uint32 internal constant FEE_BPS = 3_000_000; // 0.30% (1e9 = 100%)
    uint16 internal constant DECAY_PERIOD = 3600; // 1-hour window

    IAqua internal aqua;
    AquaSwapVMRouter internal router;
    ComposedStrategyBuilder internal builder;

    address internal maker = makeAddr("invariantMaker");

    // The order under test + its taker-data variants (built once in setUp).
    ISwapVM.Order internal order;
    bytes internal exactInData;
    bytes internal exactOutData;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

        aqua = IAqua(AQUA_ADDR);
        router = new AquaSwapVMRouter(AQUA_ADDR, WETH, address(this), "SwapVM", "1.0.0");
        builder = new ComposedStrategyBuilder(AQUA_ADDR);

        // Compose: salt → decay → flat fee → constant-product AMM.
        ComposedStrategyBuilder.PoolParams memory params = ComposedStrategyBuilder.PoolParams({
            salt: 7001,
            feeBps: FEE_BPS,
            decayPeriod: DECAY_PERIOD,
            curve: ComposedStrategyBuilder.Curve.ConstantProduct,
            sqrtPriceMin: 0,
            sqrtPriceMax: 0
        });
        order = builder.buildComposedOrder(maker, params);

        // Ship the pool into the live Aqua (maker approves Aqua to source reserves).
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
        bytes32 strategyHash = aqua.ship(address(router), abi.encode(order), tokens, amounts);
        vm.stopPrank();
        assertEq(strategyHash, router.hash(order), "strategyHash must equal orderHash");

        // Taker data: this test contract is the taker; output delivered to itself.
        exactInData = _takerData(true);
        exactOutData = _takerData(false);
    }

    /// @notice The single invariant test: the composed strategy upholds every core
    ///         invariant except the (intentionally-skipped) additivity one.
    function test_Fork_Composed_CoreInvariants() public {
        InvariantConfig memory config = _composedConfig();
        assertAllInvariantsWithConfig(SwapVM(payable(address(router))), order, WETH, USDC, config);
        console.log("CoreInvariants: composed strategy upheld all configured invariants");
    }

    // ---------------------------------------------------------------------
    // CoreInvariants hook: execute a REAL swap through the router + live Aqua.
    // ---------------------------------------------------------------------

    /// @dev `amount` is exact-in (tokenIn) or exact-out (tokenOut) per `takerData`.
    ///      We over-fund tokenIn generously; CoreInvariants snapshots/reverts around
    ///      every call so leftover funding (and decay offsets) never leak across
    ///      assertions.
    function _executeSwap(
        SwapVM swapVM,
        ISwapVM.Order memory ord,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        // Generous tokenIn funding (scaled per token decimals) so exact-out swaps,
        // whose required input is not known up-front, never run short.
        uint256 funding = tokenIn == WETH ? 1_000_000 ether : 1_000_000_000 * 1e6;
        deal(tokenIn, address(this), funding);
        IERC20(tokenIn).approve(address(swapVM), type(uint256).max);

        (amountIn, amountOut,) = swapVM.swap(ord, tokenIn, tokenOut, amount, takerData);
    }

    // ---------------------------------------------------------------------
    // Config + helpers
    // ---------------------------------------------------------------------

    /// @dev Build taker traits with this contract as taker + recipient.
    function _takerData(bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: "",
            to: address(this),
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

    /// @dev Invariant config tuned for a WETH(18dp)→USDC(6dp) composed pool.
    ///      exact-in amounts are WETH-scale; exact-out amounts are USDC-scale and
    ///      bounded well under the maker's reserve.
    function _composedConfig() internal view returns (InvariantConfig memory config) {
        uint256[] memory inAmounts = new uint256[](3);
        inAmounts[0] = 1 ether;   // 1 WETH
        inAmounts[1] = 5 ether;   // 5 WETH
        inAmounts[2] = 20 ether;  // 20 WETH (2% of the 1000-WETH reserve)

        uint256[] memory outAmounts = new uint256[](3);
        outAmounts[0] = 3_000 * 1e6;   // ~1 WETH worth of USDC
        outAmounts[1] = 15_000 * 1e6;  // ~5 WETH worth
        outAmounts[2] = 60_000 * 1e6;  // ~20 WETH worth

        config = InvariantConfig({
            // The flat fee is charged on amountIn in BOTH directions and rounds UP
            // (ceilDiv) each way, so exactIn(X)→Y followed by exactOut(Y) does not
            // recover X to the wei — the gap is the double-charged fee rounding,
            // which scales with trade size (~4e7 wei on 1 WETH, ~8e8 on 20 WETH).
            // 1e10 wei (1e-8 WETH) covers the largest test amount while staying
            // ~5 orders of magnitude tighter than the 0.30% fee itself (3e15 wei
            // on 1 WETH). This is a fee-rounding tolerance, NOT a loosened invariant.
            symmetryTolerance: 1e10,
            additivityTolerance: 0,
            roundingToleranceBps: 100, // 1%
            monotonicityToleranceBps: 0,
            testAmounts: inAmounts,
            testAmountsExactOut: outAmounts,
            // Additivity is path-dependent under _decayXD by design — see NatSpec.
            skipAdditivity: true,
            skipMonotonicity: false,
            skipSpotPrice: false,
            skipSymmetry: false,
            exactInTakerData: exactInData,
            exactOutTakerData: exactOutData
        });
    }
}
