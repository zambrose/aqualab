// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { AquaOpcodesDebug } from "@1inch/swap-vm/src/opcodes/AquaOpcodesDebug.sol";

import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { Controls, ControlsArgsBuilder } from "@1inch/swap-vm/src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "./vendor/ProgramBuilder.sol";

/// @title XYCStrategyBuilder
/// @notice Builds the minimal "happy path" SwapVM strategy: a constant-product
///         (x*y=k) AMM backed by Aqua shared liquidity.
/// @dev This is the foundational, intentionally-minimal strategy. It composes
///      exactly two SwapVM instructions:
///
///        1. XYCSwap._xycSwapXD  (opcode index 17 in the Aqua opcode table)
///           - The constant-product AMM primitive. Reads (balanceIn, balanceOut)
///             from the Aqua-backed reserves and computes amountOut (exact-in) or
///             amountIn (exact-out) such that balanceIn*balanceOut is preserved
///             (it only ever grows due to flooring/ceiling in the maker's favor).
///
///        2. Controls._salt
///           - A no-op pricing instruction whose only effect is to perturb the
///             order hash. Two otherwise-identical strategies need distinct salts
///             to ship as distinct Aqua strategies (Aqua enforces immutable,
///             unique strategy hashes). It carries no economic meaning.
///
///      Agent 2 extends this by inserting fee/decay/concentrate instructions
///      *around* the swap primitive (ordering is security-critical — see
///      swap-vm/docs/PROGRAMS.md). The extension points are `_swapProgram()` and
///      `buildXYCProgram()` below.
///
///      The builder inherits AquaOpcodesDebug purely to obtain the canonical
///      `_opcodes()` table used to resolve instruction function-pointers to their
///      opcode bytes. The debug variant only fills the reserved no-op slots
///      (indices 0..4), so the resulting program bytes are byte-identical to what
///      the production AquaSwapVMRouter (plain AquaOpcodes) executes.
contract XYCStrategyBuilder is AquaOpcodesDebug {
    using ProgramBuilder for Program;

    constructor(address aqua) AquaOpcodesDebug(aqua) { }

    /// @notice Build the raw SwapVM program bytecode for an XYCSwap AMM.
    /// @param salt Unique salt so identical pools ship as distinct Aqua strategies.
    /// @return programBytes Concatenated [opcode][len][args] instruction stream.
    function buildXYCProgram(uint64 salt) public pure returns (bytes memory programBytes) {
        Program memory p = ProgramBuilder.init(_opcodes());
        programBytes = bytes.concat(
            _swapProgram(p),
            p.build(Controls._salt, ControlsArgsBuilder.buildSalt(salt))
        );
    }

    /// @dev The AMM primitive. Overridable extension point for Agent 2 to swap in
    ///      a concentrated-liquidity primitive or wrap with fee/decay instructions.
    function _swapProgram(Program memory p) internal pure virtual returns (bytes memory) {
        return p.build(XYCSwap._xycSwapXD);
    }

    /// @notice Build a full Aqua-backed maker Order around an XYCSwap program.
    /// @dev `useAquaInsteadOfSignature = true` makes the router source/settle
    ///      reserves through Aqua (AQUA.safeBalances / pull / push) instead of an
    ///      EIP-712 signature. With this flag the maker must equal the receiver and
    ///      WETH unwrap is disallowed (enforced by SwapVM).
    /// @param maker The liquidity provider whose Aqua balances back the pool.
    /// @param salt Unique salt for the strategy hash.
    function buildOrder(address maker, uint64 salt) public pure returns (ISwapVM.Order memory order) {
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: buildXYCProgram(salt)
        }));
    }
}
