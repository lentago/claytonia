## Origin

<!-- 2–4 sentences, third-person past tense: who asked for this and what they wanted,
     including the substantive constraints. Don't quote the prompt verbatim. -->

## Summary

<!-- One or two sentences: what changed and why. Link the issue if there is one. -->

Closes #

## Checklist

- [ ] `shellcheck` passes (it gates the merge)
- [ ] No secrets committed (tokens/keys/passwords stay on the workers)
- [ ] Atomicity / claim model preserved (the `mv` is the cross-worker arbiter)
- [ ] gitops-safe: scripts pass `bash -n`, units pass `systemd-analyze verify`
- [ ] Comments explain *why*, not just *what*

## Notes for reviewer

<!-- Trade-offs, open questions, areas of uncertainty. -->
