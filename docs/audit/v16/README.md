# v1.6 internal audit rounds

One auditor per round, one lens per round (station rule), each pinned to a
commit and checked against it (`AUDITED_TREE`, every citation resolved at that
tree). The verdicts are kept as the auditor wrote them; only the worktree's
absolute path prefix was rewritten to repository-relative paths.

| Round | Tree | Lens | Verdict | What followed |
|---|---|---|---|---|
| [1](round1.txt) | `d597a05` | coverage, package 1 | HIGH 0 · MEDIUM 2 · LOW 3 | buy-back gate; insider recipients; three LOWs |
| [2](round2.txt) | `cbc014a` | endorsement, package 1 | HIGH 0 · MEDIUM 3 · LOW 4 | recipient blocklist broken twice → positive identification; ABI parity check |
| [3](round3.txt) | `4a2f99b` | coverage, package 1 + fill | HIGH 0 · MEDIUM 1 · LOW 3 | the fill's physical take broken twice → claims and `burnFilledCoin` |
| [4](round4.txt) | `3d5b2c3` | endorsement, the whole unit (Q28) | HIGH 1 · MEDIUM 2 · LOW 2 | the value cap binds after launch; redirect of what is emitted; no script in the genesis broadcast; checked route composition; 18-decimal priced quotes (plan §R4) |
| [5](round5.txt) | `163e003` | full round: coverage and endorsement — **the endorsing round** | HIGH 0 · MEDIUM 0 · LOW 1 | four package-2 guards given witnesses |
| [6](round6.txt) | `bc0f185` | value flow and conservation | HIGH 0 · MEDIUM 0 · LOW 1 | four conservation obligations given witnesses |
| [7](round7.txt) | `7bdb5fc` | time, ordering and lifecycle; finding bar in force | **PASS** | — |

The loop closed on two consecutive zero-HIGH rounds after the endorsing round
(rounds 6 and 7). `src/` and `script/` at the seal are byte-identical to the
tree round 7 audited; the seal commit adds only the bytecode pins, this record
and the seal receipt (`docs/audit-briefs/v16-unit.md`).

Two rounds needed relaunching because the model provider's content filter
stopped the auditor mid-run (round 4 twice, round 7 once); each relaunch kept
the lens and changed only wording, and each died run's log was kept with the
round's working files.
