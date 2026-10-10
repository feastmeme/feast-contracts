
## `block.number` and `vm.roll`

`foundry.toml` sets `via_ir = true`. The IR optimiser common-subexpression-
eliminates the `NUMBER` opcode across a call frame — sound on a real chain,
where the height cannot move inside a transaction, and wrong under `vm.roll`.
Two reads of `block.number` in one function, with a `vm.roll` between them, see
**one** value: silently, with no warning and no trace anomaly. Two consecutive
`vm.roll(block.number + n)` calls in one function can therefore roll to the same
height, and the second is a no-op.

Read through `vm.getBlockNumber()` — an external cheatcode call the optimiser
cannot fold — on both sides of any `vm.roll`. Reading through a contract view is
also safe, because the call frame ends. `vm.warp`/`block.timestamp` has the same
exposure. Measured 2026-09-22 writing the v1.6.15 PoCs; it cost a debugging
cycle and it is not visible in a `-vvvv` trace.
