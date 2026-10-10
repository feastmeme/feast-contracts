// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastToken} from "../src/FeastToken.sol";

contract FeastTokenTest is Test {
    FeastToken internal coin;
    address internal factory = address(0xFAC7);
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        vm.prank(factory);
        coin = new FeastToken("Coin", "COIN", SUPPLY, factory);
    }

    function test_wholeSupplyIsMintedToTheRecipientAndNowhereElse() public view {
        assertEq(coin.totalSupply(), SUPPLY, "total supply");
        assertEq(coin.balanceOf(factory), SUPPLY, "recipient holds all of it");
    }

    function test_metadata() public view {
        assertEq(coin.name(), "Coin");
        assertEq(coin.symbol(), "COIN");
        assertEq(coin.decimals(), 18);
    }

    /// I12. Fixed supply is enforced by absence: there is no mint entrypoint at
    /// all, so this asserts on the deployed bytecode rather than on a modifier.
    function test_noMintEntrypointExists() public {
        (bool ok,) = address(coin).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok, "mint(address,uint256)");
        (ok,) = address(coin).call(abi.encodeWithSignature("mint(address,uint256,bytes)", address(this), 1, ""));
        assertFalse(ok, "mint(address,uint256,bytes)");
    }

    /// The reference this is trimmed from carries an admin that can reassign
    /// itself and rewrite the token's metadata. A mutable admin is an owner
    /// function under another name, so none of these may resolve.
    function test_noAdminSurfaceExists() public {
        string[7] memory sigs = [
            "owner()",
            "admin()",
            "updateAdmin(address)",
            "updateImage(string)",
            "updateMetadata(string)",
            "verify()",
            "isVerified()"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(coin).call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, sigs[i]);
        }
    }

    function test_burnReducesTotalSupply() public {
        vm.prank(factory);
        coin.burn(100e18);
        assertEq(coin.totalSupply(), SUPPLY - 100e18, "supply after burn");
        assertEq(coin.balanceOf(factory), SUPPLY - 100e18, "balance after burn");
    }

    function test_burnFromRespectsAllowance() public {
        address burner = address(0xB0);
        vm.prank(factory);
        coin.approve(burner, 50e18);

        vm.prank(burner);
        vm.expectRevert();
        coin.burnFrom(factory, 51e18);

        vm.prank(burner);
        coin.burnFrom(factory, 50e18);
        assertEq(coin.totalSupply(), SUPPLY - 50e18);
    }

    function test_permitWorks() public {
        uint256 pk = 0xA11CE;
        address owner = vm.addr(pk);
        vm.prank(factory);
        coin.transfer(owner, 1e18);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(this),
                1e18,
                coin.nonces(owner),
                block.timestamp + 1
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", coin.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        coin.permit(owner, address(this), 1e18, block.timestamp + 1, v, r, s);
        assertEq(coin.allowance(owner, address(this)), 1e18, "permit set the allowance");
    }

    /// A supply of zero would create a coin whose pool can never be seeded, and
    /// a zero recipient would burn the entire supply at construction. Both are
    /// creator mistakes that are free to refuse and permanent to accept.
    function test_refusesZeroSupplyAndZeroRecipient() public {
        vm.expectRevert(FeastToken.ZeroSupply.selector);
        new FeastToken("a", "b", 0, factory);

        vm.expectRevert(FeastToken.ZeroRecipient.selector);
        new FeastToken("a", "b", SUPPLY, address(0));
    }

    function testFuzz_transfersConserveSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != factory);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(factory);
        coin.transfer(to, amount);
        assertEq(coin.balanceOf(factory) + coin.balanceOf(to), SUPPLY, "conservation");
        assertEq(coin.totalSupply(), SUPPLY, "transfers never change supply");
    }
}
