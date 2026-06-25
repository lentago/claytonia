## Summary

<!-- What changed and why, in a neutral, objective, action-oriented voice.
     Cover the who/what/why woven in: what the change does, the motivation
     behind it, and the substantive constraints. No "X wanted…" narrative and
     no separate Origin section; don't quote the prompt verbatim. Link the
     issue if there is one. -->

Closes #

## Checklist

- [ ] `shellcheck` passes (it gates the merge)
- [ ] No secrets committed (tokens/keys/passwords stay on the workers)
- [ ] Atomicity / claim model preserved (the `mv` is the cross-worker arbiter)
- [ ] gitops-safe: scripts pass `bash -n`, units pass `systemd-analyze verify`
- [ ] Comments explain *why*, not just *what*

## Notes for reviewer

<!-- Trade-offs, open questions, areas of uncertainty. -->
