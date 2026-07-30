# Sol replacements for the FP-RISC tools/*.sh

Copy these into the qos-fpr repo's `tools/` directory and run from the repo
root:

    sol tools/sweep.sol

* `harness.sol` — shared helpers (string search/split/trim, expectation
  checking, `sh` wrappers, a realtime progress logger).
* `sweep.sol` — replaces `posix-sweep.sh`. 21 cases as Sol values instead of a
  here-doc table parsed by `IFS='|' read`. Verified 21/21 pass.

The report is written transactionally (complete or absent); the progress log
uses `appendNow` so the sweep is tailable while it runs. See
`../NOTES-realtime-bstr.md` section 4.
