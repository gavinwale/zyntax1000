// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ZynTax} from "../src/ZynTax.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";

contract ZynTaxTest is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ZynTax public hook;
    PoolId public poolId;
    TestERC20 public zyntaxToken;
    TestERC20 public otherToken;
    PoolKey public poolKey;
    address public constant MARKETING_WALLET = address(0x123);

    // Constants
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes constant ZERO_BYTES = "";
    uint160 constant MIN_SQRT_RATIO = 4295128740;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970341;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    function setUp() public {
        // Deploy the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        zyntaxToken = new TestERC20(2**128);
        otherToken = new TestERC20(2**128);

        // Deploy the hook using HookMiner to get the correct address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG, type(ZynTax).creationCode, abi.encode(address(manager), address(zyntaxToken), MARKETING_WALLET));
        hook = new ZynTax{salt: salt}(IPoolManager(manager), address(zyntaxToken), MARKETING_WALLET);
        require(address(hook) == hookAddress, "ZynTaxTest: hook address mismatch");

        // Create the pool
        poolKey = PoolKey(Currency.wrap(address(zyntaxToken)), Currency.wrap(address(otherToken)), 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1, ZERO_BYTES);

        // Approve tokens
        zyntaxToken.approve(address(manager), type(uint256).max);
        otherToken.approve(address(manager), type(uint256).max);

        // Provide liquidity to the pool
        manager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                owner: address(this), // Added owner parameter
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: 1000000 ether
            }),
            ZERO_BYTES
        );
    }

    function testZynTaxHook() public {
        uint256 initialBalance = zyntaxToken.balanceOf(address(this));

        // Perform a swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 100 ether,
            sqrtPriceLimitX96: MIN_SQRT_RATIO + 1
        });

        BalanceDelta delta = manager.swap(poolKey, params, ZERO_BYTES);

        // Calculate the actual tax
        int128 amount0 = delta.amount0();
        uint256 amount0Out = amount0 < 0 ? uint256(-amount0) : uint256(amount0);
        uint256 actualTax = initialBalance - zyntaxToken.balanceOf(address(this)) - amount0Out;

        // Check that the hook collected taxes
        assertGt(zyntaxToken.balanceOf(address(0xdead)), 0, "Burn tax not collected");
        assertGt(zyntaxToken.balanceOf(MARKETING_WALLET), 0, "Marketing tax not collected");
        assertGt(hook.totalReflections(), 0, "Reflections not collected");
        assertGt(hook.totalLiquidityTokens(), 0, "Liquidity tokens not collected");

        // Check that the total tax is correct (6% of 100 ether)
        uint256 expectedTax = 6 ether;
        assertEq(actualTax, expectedTax, "Total tax amount is incorrect");
    }
}