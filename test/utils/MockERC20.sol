// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev So a mock coin can be bought back and burned like a real one.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// A quote token that can be frozen by whoever holds the pauser role, mirroring
/// the real tokenised-stock proxies feast is paired against. Used to prove that
/// a hostile or merely cautious quote issuer cannot corrupt feast's accounting.
contract PausableMockERC20 is MockERC20 {
    bool public isPaused;
    address public immutable pauser;

    error TokenPaused();

    constructor(string memory n, string memory s, uint8 d, address pauser_) MockERC20(n, s, d) {
        pauser = pauser_;
    }

    function setPaused(bool p) external {
        require(msg.sender == pauser, "not pauser");
        isPaused = p;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (isPaused) revert TokenPaused();
        super._update(from, to, value);
    }
}


/// A quote token that calls back into a target on every transfer, so a
/// reentrancy guard can be exercised rather than asserted.
contract ReentrantMockERC20 is MockERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public fired;
    bool public lastCallOk;
    /// @notice Which transfer to fire on. The first transfer of a conversion is
    ///         the vault payout, which happens inside the vault's own lock —
    ///         and the vault refuses to be re-entered there whatever this
    ///         contract does. Firing later, on the converter's pull, is where a
    ///         reentrancy guard is the only thing standing in the way.
    uint256 public fireOnTransfer = 1;
    uint256 public transfers;

    constructor(string memory n, string memory s, uint8 d) MockERC20(n, s, d) {}

    function arm(address target_, bytes calldata payload_, uint256 nth) external {
        target = target_;
        payload = payload_;
        armed = true;
        fired = false;
        fireOnTransfer = nth;
        transfers = 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        transfers += 1;
        if (armed && !fired && transfers >= fireOnTransfer && target != address(0)) {
            fired = true;
            // Deliberately ignoring the result: the point is whether the
            // re-entrant call is refused, not whether this one reverts.
            (bool ok,) = target.call(payload);
            lastCallOk = ok;
        }
    }
}
