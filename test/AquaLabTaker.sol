// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

/// @title AquaLabTaker
/// @notice Minimal taker contract that routes a swap through the AquaSwapVMRouter.
/// @dev We use the `useTransferFromAndAquaPush` taker mode: the router pulls
///      `tokenIn` from this contract via `transferFrom` and pushes it into the
///      maker's Aqua balance itself. So all this taker has to do is hold the
///      input tokens and approve the router. The output tokens are delivered to
///      `takerTraits.to` (we set that to this contract).
contract AquaLabTaker {
    ISwapVM public immutable ROUTER;

    constructor(ISwapVM router) {
        ROUTER = router;
    }

    /// @notice Approve the router to pull a token (called once before swapping).
    function approveRouter(address token, uint256 amount) external {
        IERC20(token).approve(address(ROUTER), amount);
    }

    /// @notice Execute a swap through the router.
    function swap(
        ISwapVM.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = ROUTER.swap(order, tokenIn, tokenOut, amount, takerTraitsAndData);
    }
}
