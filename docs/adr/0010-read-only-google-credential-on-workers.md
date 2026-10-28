# ADR-0010: A read-only Google credential on the workers

**Status:** Accepted (2026-10-28).

## Context

The scheduled routines that moved onto the fleet on 2026-10-28 (see
[ADR-0009](0009-policy-gated-auto-merge-for-routine-prs.md)) read the
maintainer's Gmail, Calendar and Drive. As hosted cloud agents they used
claude.ai's connectors. A worker authenticates with a `claude setup-token`
token, and the connectors don't come with it: `claude mcp list` on a worker
shows none.

## Decision

**Each worker holds one read-only Google OAuth refresh token, and jobs reach
Google through `bin/google-read`.**

- The maintainer creates a "Desktop app" OAuth client in a Google Cloud project
  of their own, publishes it (a Testing-mode client's refresh tokens expire after
  7 days), and runs `bin/google-auth` once on a desktop. It requests exactly
  `gmail.readonly`, `calendar.readonly` and `drive.metadata.readonly`, refuses to
  save a token carrying any other Google API scope, and writes the result to a
  0600 file without printing it.
- That file is installed on every worker as `/etc/claude-runner/google.env`,
  `root:claude 0640`, beside `token.env` and `gh-app.pem`. Workers are cattle
  (ADR-0003), so a job can land anywhere and the credential has to be everywhere;
  a provisioned or rebuilt worker gets it the same way it gets `token.env`.
- `google-read` is the only intended path. It refreshes an access token per call
  and keeps nothing on disk. Its sole POST is the token refresh; every API call is
  a GET to the Gmail, Calendar or Drive read endpoints, refused otherwise.
  `google-read check` prints the account and the scopes the token carries.

## Alternatives

- **claude.ai connectors on the workers.** Not available to a `setup-token`
  login.
- **IMAP with an app password.** Worse: an app password is full mailbox access,
  including delete and send through SMTP, with no read-only form.
- **One designated worker holding the credential.** Worse: it makes a pet (the
  ADR-0003 retrospective rejects sticky workers), and every job already runs with
  `sudo` on its worker, so pinning narrows only which jobs could read it, not the
  kind of access.
- **A broker service on the LAN that holds the token and answers the workers.**
  Lateral, and a new service to run. It would keep the token off the workers, but
  any job could still ask the broker for the same data.

## Consequences

- **Any job on any worker can read the maintainer's mail, calendar and Drive file
  list.** Jobs run with permissions skipped and `sudo`, and many read untrusted
  content (web pages, issues), so a prompt injection could exfiltrate mail. The
  scopes bound the damage to disclosure: the token cannot send, delete, label or
  change anything, which is narrower than the hosted connector it replaces.
- Revoking it is one click at myaccount.google.com/permissions (or deleting the
  OAuth client), and every worker loses access at once.
- `google-read` adds no dependency beyond `python3`, already on the workers.
- The routines' specs, not this repository, say which mail to read; nothing here
  names the account or its use.
