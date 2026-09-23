#!/bin/bash
# Throwaway. Proves per-process GH_TOKEN and GIT_SSH_COMMAND select the GitHub account. Read-only.
set -uo pipefail
login="${1:?usage: probe-gh-token.sh <gh-login> <owner/private-repo> [ssh-key-path]}"
repo="${2:?usage: probe-gh-token.sh <gh-login> <owner/private-repo> [ssh-key-path]}"
ssh_key="${3:-}"
export GIT_TERMINAL_PROMPT=0

echo "active account: $(gh api user --jq .login)"
token="$(gh auth token --user "$login")"
echo "with GH_TOKEN: $(GH_TOKEN="$token" gh api user --jq .login)"

if git ls-remote "https://github.com/$repo.git" HEAD >/dev/null 2>&1; then
  echo "git https without GH_TOKEN: ok (repo visible to the active account; pick a repo it cannot see)"
else
  echo "git https without GH_TOKEN: denied"
fi
if GH_TOKEN="$token" git ls-remote "https://github.com/$repo.git" HEAD >/dev/null 2>&1; then
  echo "git https with GH_TOKEN: ok"
else
  echo "git https with GH_TOKEN: denied"
fi

if [ -n "$ssh_key" ]; then
  # -F /dev/null: ~/.ssh/config "Host github.com" would otherwise add id_rsa_personal.
  ssh_command="ssh -F /dev/null -i $ssh_key -o IdentitiesOnly=yes"
  echo "ssh identity: $($ssh_command -T git@github.com 2>&1 | head -1)"
fi
