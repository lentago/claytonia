#!/usr/bin/env bash
# Install gh CLI + GitHub App token plumbing in the runner. No secrets here —
# APP_ID / INSTALLATION_ID / the .pem are filled in by Chris after App creation.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">>> install gh CLI"
if ! command -v gh >/dev/null 2>&1; then
  mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq && apt-get install -y -qq gh >/dev/null
fi
gh --version | head -1

echo ">>> gh-token minter"
cat > /opt/claude-runner/bin/gh-token <<'GHTOKEN'
#!/usr/bin/env bash
# gh-token [owner/repo] — print a short-lived (~1h) GitHub App installation token.
# Config: /etc/claude-runner/gh-app.env  (APP_ID=, optional INSTALLATION_ID=)
#         /etc/claude-runner/gh-app.pem  (App private key)
set -euo pipefail
ENVF=/etc/claude-runner/gh-app.env
PEM=/etc/claude-runner/gh-app.pem
[ -f "$ENVF" ] && . "$ENVF"
: "${APP_ID:?APP_ID not set in $ENVF}"
[ -s "$PEM" ] || { echo "gh-token: missing/empty $PEM" >&2; exit 1; }

b64url(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
hdr=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
pld=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now-60))" "$((now+540))" "$APP_ID" | b64url)
sig=$(printf '%s' "$hdr.$pld" | openssl dgst -sha256 -sign "$PEM" -binary | b64url)
jwt="$hdr.$pld.$sig"
ghapi(){ curl -fsSL -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
                    -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

inst="${INSTALLATION_ID:-}"
repo="${1:-${GH_REPO:-}}"
if [ -z "$inst" ]; then
  [ -n "$repo" ] || { echo "gh-token: set INSTALLATION_ID in $ENVF, or pass owner/repo" >&2; exit 1; }
  inst=$(ghapi "https://api.github.com/repos/$repo/installation" | jq -r .id)
fi
[ -n "$inst" ] && [ "$inst" != null ] || { echo "gh-token: cannot resolve installation id" >&2; exit 1; }

ghapi -X POST "https://api.github.com/app/installations/$inst/access_tokens" | jq -r .token
GHTOKEN

echo ">>> git credential helper (re-mints per op; token never persisted)"
cat > /opt/claude-runner/bin/gh-credential-helper <<'CREDH'
#!/usr/bin/env bash
# git credential helper backed by the GitHub App. Re-mints on each 'get'.
[ "${1:-}" = get ] || exit 0
tok="$(/usr/local/bin/gh-token 2>/dev/null)" || exit 0
echo "username=x-access-token"
echo "password=$tok"
CREDH

chmod +x /opt/claude-runner/bin/gh-token /opt/claude-runner/bin/gh-credential-helper
ln -sf /opt/claude-runner/bin/gh-token /usr/local/bin/gh-token
ln -sf /opt/claude-runner/bin/gh-credential-helper /usr/local/bin/gh-credential-helper

echo ">>> App config placeholder (you fill APP_ID/INSTALLATION_ID; drop the .pem)"
if [ ! -f /etc/claude-runner/gh-app.env ]; then
  printf 'APP_ID=\nINSTALLATION_ID=\n' > /etc/claude-runner/gh-app.env
  chown root:claude /etc/claude-runner/gh-app.env
  chmod 640 /etc/claude-runner/gh-app.env
fi
touch /etc/claude-runner/gh-app.pem
chown root:claude /etc/claude-runner/gh-app.pem
chmod 640 /etc/claude-runner/gh-app.pem

echo ">>> configure git for the claude user (bot identity + App credential helper)"
su - claude -c '
  git config --global user.name  "claude-runner[bot]"
  git config --global user.email "claude-runner[bot]@users.noreply.github.com"
  git config --global credential.https://github.com.helper "/usr/local/bin/gh-credential-helper"
  git config --global init.defaultBranch main
  git config --global --list | grep -E "user\.|credential\."
'
echo GH_SETUP_DONE
