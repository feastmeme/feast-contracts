# Round 1, lens B — endorsement

## Your standing

You are a senior reviewer seeing this codebase for the first time, asked whether
you would personally endorse it for an internal v1. You owe nothing to any prior
framing, including the framing in its own documents. Your job is not to find the
cleverest attack — the other lens is doing that — but to answer a narrower and
in some ways harder question:

**Does the shipped code do what its documents say it does, no more and no less?**

## What to read, in this order

1. `docs/plan.md` — the design, the invariant list (§3, I1–I14), the refusal
   ledger (§4), and §0, which records the rulings the design was built against.
2. `docs/interface.md` — what the application is told it can rely on.
3. `README.md` — the promises table, the deployment recipe, the section headed
   "What feast does not control".
4. `src/` — the code.
5. `test/` — what is actually held, and by what.
6. `docs/mutations.md` and `tools/mutate.py` — what the tests are claimed to
   catch.

Everything under `lib/` and `reference/` is vendored third-party code and is not
the subject.

## The three questions

**One: is every invariant exercised?** `docs/plan.md` §3 lists fourteen. For each,
find the test that would fail if the invariant broke, and say whether it would
actually fail — or whether it asserts something adjacent to the invariant and
would stay green through a real violation. An invariant with no test, or with a
test that cannot fail for the stated reason, is a finding. Be specific about
which of the two you found.

**Two: is any claim broader than its evidence?** Go through the normative
sentences in the three documents and the doc comments in `src/`, and mark any
that assert more than the code or the tests support. Two examples of the shape,
both already caught and corrected during the build, so you know the register:

- a comment claimed that validating a route before moving funds means a refused
  conversion "never touches the caller's balance" — but the whole call reverts
  either way, so no test could distinguish it. The real property was legibility,
  and the comment now says so.
- a test asserted a swap's price limit exactly in one token ordering and only
  its direction in the other, so a limit of the right sign and wrong size passed.

Claims about what "cannot" happen deserve the most scrutiny. There is no owner,
no upgrade path, no pause: check that these are true of the code rather than of
the intention. `tools/check-boundaries.py` greps for the surfaces; a grep is not
a proof, so look for authority that does not spell itself `onlyOwner`.

**Three: is the original mandate fully solved, or partly?** The product is
described at the top of `README.md` and in `docs/plan.md` §2. Is anything
half-built, silently dropped, or present in the documents but absent from the
code? Name it plainly. In particular, walk the money: a fee is taken, divided
four ways, and each share must reach somewhere a person can get it or a place it
provably cannot leave. Follow each of the four to its end and say whether it
arrives. If any share can become stranded — unreachable by its owner and
unusable by anyone — that is the finding this lens exists to catch.

## Specific things to check rather than assume

- **The deployment recipe in `README.md` is executable as written.** The
  contracts take each other's addresses as immutable constructor arguments, so
  the order and the address predictions matter. Would following the recipe
  literally produce a working system?
- **`docs/interface.md` matches the ABI.** The application is being handed
  function names and behaviours; check they exist with those signatures and mean
  what the document says. `docs/abi/*.json` is generated from the code.
- **The provisional quote tokens.** `docs/quote-survey.json` and
  `tools/discover_quotes.py` identify quote tokens by symbol and verify them on
  chain. The fork tests use those addresses and label them provisional. Is the
  labelling honest and is the survey's reasoning sound — particularly the claim
  that a pool holding one observation reports its spot price as its
  time-weighted price, and that this is why such pools are refused?
- **The governed parameter.** Exactly one number is meant to be changeable.
  Confirm that is true, that its band is enforced where the documents say, and
  that the documents describe the timing correctly.
- **Rounding, stated honestly.** Several places divide. Where the documents claim
  exactness, is it exact? Where they claim a bound, is the bound the one stated?

## A boundary, not a defect

The venue does not invoke a hook's callbacks when the hook is itself the
swapper, and feast relies on this for its buy-back. The documents state it. If
you think the reliance is misstated or misplaced, that is a finding; that the
reliance exists is not.

The venue can be paused by its own operator, and takes a share of the LP fee at
a rate its operator sets. `README.md` says so under "What feast does not
control". Neither is a finding; a document that failed to say so would be.

## What endorsement means

PASS from you means you would personally sign this off for an internal v1 —
that the documents are true, the invariants are held rather than asserted, and
nothing in the mandate is quietly missing. If you would not sign it off, say
what would have to change. Do not pad a verdict to look thorough; a clean
codebase should receive a clean verdict, and an unclean one should receive
specifics.

## Output

Follow the output contract in the header above. Group findings by severity with
`file:line` evidence at the pinned commit. Include an explicit completeness
section covering question three.
