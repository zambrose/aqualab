// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd
/// @dev Vendored verbatim from swap-vm/test/utils/ProgramBuilder.sol so that
///      production strategy-builder code (src/) does not reach into the upstream
///      test tree. Encodes a SwapVM program as a stream of
///      [opcode:uint8][argsLength:uint8][args] frames, resolving each instruction
///      function-pointer to its index in the router's _opcodes() table.

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";

struct Program {
    function(Context memory, bytes calldata) internal[] opcodes;
}

library ProgramBuilder {
    using SafeCast for uint256;

    error OpcodeNotFound();

    function init(function(Context memory, bytes calldata) internal[] memory opcodes) internal pure returns (Program memory) {
        return Program({ opcodes: opcodes });
    }

    function build(Program memory self, function(Context memory, bytes calldata) internal instruction) internal pure returns (bytes memory) {
        return build(self, instruction, "");
    }

    function build(Program memory self, function(Context memory, bytes calldata) internal instruction, bytes memory args) internal pure returns (bytes memory) {
        uint8 opcode = findOpcode(self, instruction);
        return abi.encodePacked(opcode, args.length.toUint8(), args);
    }

    function findOpcode(Program memory self, function(Context memory, bytes calldata) internal targetOpcode) internal pure returns (uint8) {
        for (uint256 i = 0; i < self.opcodes.length; i++) {
            if (self.opcodes[i] == targetOpcode) {
                return i.toUint8();
            }
        }
        revert OpcodeNotFound();
    }
}
