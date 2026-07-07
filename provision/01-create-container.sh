#!/usr/bin/env bash
# LEGACY / REFERENCE (2026-07-07, #54): superseded by the kalmia runner image.
# The substrate this lays down is now baked in kalmia forge/runner/substrate.sh;
# kept for provenance, not part of the current build path.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">>> installing packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates git jq ripgrep inotify-tools sudo python3 less openssh-server tini >/dev/null
echo "PKGS_OK"

echo ">>> creating claude user"
id claude >/dev/null 2>&1 || useradd -m -s /bin/bash claude
echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude
chmod 440 /etc/sudoers.d/claude
echo "USER_OK"

echo ">>> installing SSH key (root + claude)"
PUBKEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCbnPjDFmbYusUw13NsD5h+NMRA/l8JAjaSZF94ohUvMQvXTY5ozTnBl5fWtd9UHof9ftE4hLdih/sSdDxRJAtq9SSCSb4OuFsEy+CFJpM6/f6mtsCjrL3TE11f5M6hiGX7423gdW0FXBLgC6klTWK023lt21S9VU0um6XIPicdsMg8udOVKSYPquPSq6XhB7ngpPjN7XdELfzSJYAwlgTaoFjw1ZvdQfMRslCXdx/AhbKBSlQKBsf/LkLZJCZACvt1+Z1vZtJr7kq7WqANEzJqrTZWDTF5NnEPU6eHDVqCh8lZZkaBY6cTNIIugwW3UMSrbw3I40OD9/qGpleyLowmf8cxX1WHY/HbVAxpmxYbWO5f4N9l6lFe6tdVwaTGtlj3jEJFM/CPZP6ygp6m9OqgaXXwSG6vFuJKz4XQvtF3hBmRs+vlzgflkF+5h/qKh+e29g/bkj82zMA8cfIdwoT9n2DdP3LHIfSFo/l9l9AANPKHFtvZq6saHIx5Dp/Pd8M= cpitzi@penguin'
for u in root claude; do
  if [ "$u" = root ]; then H=/root; else H=/home/claude; fi
  mkdir -p "$H/.ssh"; chmod 700 "$H/.ssh"
  touch "$H/.ssh/authorized_keys"
  grep -qF "$PUBKEY" "$H/.ssh/authorized_keys" || echo "$PUBKEY" >> "$H/.ssh/authorized_keys"
  chmod 600 "$H/.ssh/authorized_keys"
done
chown -R claude:claude /home/claude/.ssh
systemctl enable ssh >/dev/null 2>&1 || true
systemctl restart ssh
echo "SSH_OK"

echo ">>> installing Claude Code (native installer, as claude)"
su - claude -c 'curl -fsSL https://claude.ai/install.sh | bash' 2>&1 | tail -8
su - claude -c 'grep -q ".local/bin" ~/.bashrc || echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.bashrc'
su - claude -c 'export PATH=$HOME/.local/bin:$PATH; claude --version' && echo "CLAUDE_OK"
