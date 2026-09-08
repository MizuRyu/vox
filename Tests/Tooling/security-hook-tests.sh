#!/usr/bin/env bash
set -euo pipefail

project_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
fixtures_root="$(mktemp -d "${TMPDIR:-/tmp}/vox-security-tests.XXXXXX")"
trap 'rm -rf "$fixtures_root"' EXIT

pass_count=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

new_repo() {
  local name="$1"
  local repo="$fixtures_root/$name"

  mkdir -p "$repo/scripts" "$repo/.semgrep"
  cp "$project_root/scripts/security" "$repo/scripts/security"
  cp "$project_root/scripts/lint" "$repo/scripts/lint"
  cp "$project_root/scripts/setup" "$repo/scripts/setup"
  cp "$project_root/.gitignore" "$repo/.gitignore"
  cp "$project_root/.gitleaks.toml" "$repo/.gitleaks.toml"
  cp "$project_root/.semgrep/security.yml" "$repo/.semgrep/security.yml"
  cp "$project_root/.swiftlint.yml" "$repo/.swiftlint.yml"
  cp "$project_root/lefthook.yml" "$repo/lefthook.yml"
  git -C "$repo" init -q
  git -C "$repo" config user.email 'tooling-test@example.invalid'
  git -C "$repo" config user.name 'Tooling Test'
  printf '%s\n' "$repo"
}

expect_pass() {
  local name="$1"
  shift
  if ! "$@" >"$fixtures_root/output" 2>&1; then
    sed -n '1,120p' "$fixtures_root/output" >&2
    fail "$name"
  fi
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$name"
}

expect_reject_without_value() {
  local name="$1"
  local forbidden="$2"
  shift 2
  if "$@" >"$fixtures_root/output" 2>&1; then
    fail "$name (unexpected success)"
  fi
  if grep -Fq "$forbidden" "$fixtures_root/output"; then
    fail "$name (secret value was printed)"
  fi
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$name"
}

expect_reject_with_message() {
  local name="$1"
  local expected="$2"
  shift 2
  if "$@" >"$fixtures_root/output" 2>&1; then
    fail "$name (unexpected success)"
  fi
  if ! grep -Fq "$expected" "$fixtures_root/output"; then
    sed -n '1,120p' "$fixtures_root/output" >&2
    fail "$name (expected diagnostic was missing)"
  fi
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$name"
}

expect_fail() {
  local name="$1"
  shift
  if "$@" >"$fixtures_root/output" 2>&1; then
    fail "$name (unexpected success)"
  fi
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$name"
}

install_lefthook() {
  local repo="$1"
  local install_bin="$repo/.tooling-install-bin"

  mkdir -p "$install_bin"
  cp "$(command -v lefthook)" "$install_bin/lefthook"
  (cd "$repo" && PATH="$install_bin:$PATH" scripts/setup)
  mv "$install_bin/lefthook" "$install_bin/lefthook.unavailable"
}

run_pre_commit_hook() {
  local repo="$1"
  (cd "$repo" && .git/hooks/pre-commit)
}

clean_repo="$(new_repo clean)"
printf 'public fixture\n' >"$clean_repo/file with spaces.txt"
ln -s 'file with spaces.txt' "$clean_repo/public-link"
git -C "$clean_repo" add .
expect_pass 'clean initial index with spaces and symlink passes' \
  "$clean_repo/scripts/security" --staged
expect_pass 'Lefthook installs in a clean initial repository' \
  install_lefthook "$clean_repo"
expect_pass 'installed pre-commit hook allows the clean initial index' \
  run_pre_commit_hook "$clean_repo"

missing_lefthook_bin="$clean_repo/missing-lefthook-bin"
mkdir -p "$missing_lefthook_bin"
ln -s "$(command -v git)" "$missing_lefthook_bin/git"
expect_reject_with_message 'setup-installed hook fails closed when Lefthook is missing' \
  "required tool 'lefthook' is missing" \
  env "PATH=$missing_lefthook_bin" "$clean_repo/.git/hooks/pre-commit"
expect_pass 'LEFTHOOK=0 explicitly bypasses the installed hook' \
  env LEFTHOOK=0 "PATH=$missing_lefthook_bin" "$clean_repo/.git/hooks/pre-commit"

secret_prefix='xoxb-'
secret_body_a='123456789012-123456789012-'
secret_body_b='abcdefghijklmnopqrstuvwx'
fake_secret="${secret_prefix}${secret_body_a}${secret_body_b}"

secret_repo="$(new_repo secret)"
printf 'token=%s\n' "$fake_secret" >"$secret_repo/config.txt"
git -C "$secret_repo" add .
expect_reject_without_value 'staged fake secret is rejected without disclosure' "$fake_secret" \
  "$secret_repo/scripts/security" --staged
expect_pass 'Lefthook installs in the secret fixture repository' \
  install_lefthook "$secret_repo"
expect_reject_without_value 'installed pre-commit hook rejects the staged secret' "$fake_secret" \
  run_pre_commit_hook "$secret_repo"

partial_repo="$(new_repo partial)"
printf 'token=public-fixture\n' >"$partial_repo/config.txt"
git -C "$partial_repo" add .
git -C "$partial_repo" commit -qm 'fixture base'
printf 'token=%s\n' "$fake_secret" >"$partial_repo/config.txt"
git -C "$partial_repo" add config.txt
printf 'token=clean-working-tree\n' >"$partial_repo/config.txt"
expect_reject_without_value 'partially staged secret is rejected without disclosure' "$fake_secret" \
  "$partial_repo/scripts/security" --staged

dangerous_repo="$(new_repo dangerous-code)"
printf '%s\n' 'import subprocess' 'subprocess.run("echo safe", shell=True)' >"$dangerous_repo/example.py"
git -C "$dangerous_repo" add .
expect_reject_without_value 'local Semgrep rule rejects shell=True' 'echo safe' \
  "$dangerous_repo/scripts/security" --staged

swift_repo="$(new_repo dangerous-swift)"
mkdir -p "$swift_repo/Sources"
printf '%s\n' \
  'process.executableURL = URL(fileURLWithPath: "/bin/zsh")' \
  'process.arguments = ["-c", command]' >"$swift_repo/Sources/Runner.swift"
git -C "$swift_repo" add .
expect_reject_without_value 'generic Swift rule rejects a direct shell command string' 'command' \
  "$swift_repo/scripts/security" --staged

personal_path_repo="$(new_repo personal-path)"
printf '/Users/%s/project\n' 'private-owner' >"$personal_path_repo/notes.txt"
git -C "$personal_path_repo" add .
expect_reject_without_value 'personal absolute path is rejected' 'private-owner' \
  "$personal_path_repo/scripts/security" --staged

deleted_repo="$(new_repo deletion)"
printf 'temporary\n' >"$deleted_repo/deleted.txt"
git -C "$deleted_repo" add .
git -C "$deleted_repo" commit -qm 'fixture base'
rm "$deleted_repo/deleted.txt"
git -C "$deleted_repo" add -u
expect_pass 'staged deletion passes' "$deleted_repo/scripts/security" --staged

broken_repo="$(new_repo broken-config)"
printf 'public fixture\n' >"$broken_repo/readme.txt"
git -C "$broken_repo" add .
printf 'rules: [invalid\n' >"$broken_repo/.semgrep/security.yml"
git -C "$broken_repo" add .semgrep/security.yml
expect_reject_without_value 'invalid scanner configuration fails closed' 'public fixture' \
  "$broken_repo/scripts/security" --staged

lint_error_repo="$(new_repo lint-error)"
printf '%s\n' '#!/usr/bin/env bash' 'if true; then' >"$lint_error_repo/scripts/broken"
chmod +x "$lint_error_repo/scripts/broken"
git -C "$lint_error_repo" add .
expect_reject_with_message 'invalid staged shell script is rejected by lint' 'error' \
  "$lint_error_repo/scripts/lint" --staged

missing_tool_repo="$(new_repo missing-tool)"
missing_tool_bin="$missing_tool_repo/minimal-bin"
mkdir -p "$missing_tool_bin"
ln -s "$(command -v bash)" "$missing_tool_bin/bash"
ln -s "$(command -v git)" "$missing_tool_bin/git"
expect_reject_with_message 'missing security tool fails closed' "required tool 'gitleaks' is missing" \
  env "PATH=$missing_tool_bin" "$missing_tool_repo/scripts/security" --staged

ignore_repo="$(new_repo ignore-rules)"
mkdir -p "$ignore_repo/recordings" "$ignore_repo/benchmarks/m0/audio" "$ignore_repo/benchmarks/m0"
touch "$ignore_repo/.env" "$ignore_repo/private.key" "$ignore_repo/recordings/sample.wav" \
  "$ignore_repo/benchmarks/m0/audio/sample.wav" "$ignore_repo/.env.example" \
  "$ignore_repo/benchmarks/m0/manifest.example.tsv" "$ignore_repo/flake.nix"
expect_pass 'private artifacts are ignored' \
  git -C "$ignore_repo" check-ignore .env private.key recordings/sample.wav benchmarks/m0/audio/sample.wav
expect_fail 'public examples and Nix declarations remain addable' \
  git -C "$ignore_repo" check-ignore .env.example benchmarks/m0/manifest.example.tsv flake.nix

printf '1..%d\n' "$pass_count"
