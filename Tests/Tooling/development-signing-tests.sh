#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/vox-development-signing-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fixture_root="$temporary_root/project"
mkdir -p "$fixture_root/scripts" "$fixture_root/Resources/App" "$temporary_root/bin"
cp "$project_root/scripts/bundle-app" "$project_root/scripts/make-app-icon" \
  "$project_root/scripts/validate-app" "$fixture_root/scripts/"
cp "$project_root/Resources/App/Info.plist" "$project_root/Resources/App/Vox.entitlements" \
  "$fixture_root/Resources/App/"
printf '1.0.0\n' >"$fixture_root/VERSION"
git -C "$fixture_root" init -q
git -C "$fixture_root" add .
git -C "$fixture_root" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture

cc "$project_root/Tests/Tooling/sleeper.c" -o "$temporary_root/Vox"
sips -c 1024 1024 "$project_root/images/settings.png" \
  --out "$temporary_root/AppIcon.png" >/dev/null

fingerprint='0123456789ABCDEF0123456789ABCDEF01234567'
signing_log="$temporary_root/codesign.log"
cat >"$temporary_root/bin/security" <<'SH'
#!/usr/bin/env bash
if [[ "${VOX_TEST_IDENTITY_AVAILABLE:-}" == '1' ]]; then
  printf '  1) %s "%s"\n' "$VOX_TEST_FINGERPRINT" "${VOX_TEST_IDENTITY_NAME:-Apple Development: Fixture}"
fi
SH
cat >"$temporary_root/bin/codesign" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VOX_TEST_SIGNING_LOG"
if [[ " $* " == *" --sign $VOX_TEST_FINGERPRINT "* ]]; then
  [[ "${VOX_TEST_SIGNING_FAILURE:-}" != '1' ]] || exit 42
  args=("$@")
  for ((index = 0; index < ${#args[@]}; index++)); do
    if [[ "${args[$index]}" == '--sign' ]]; then
      args[$((index + 1))]='-'
    elif [[ "${args[$index]}" == '--timestamp=none' ]]; then
      unset 'args[index]'
    fi
  done
  exec /usr/bin/codesign "${args[@]}"
fi
if [[ " $* " == *' -R '* ]]; then
  [[ "${VOX_TEST_INCOMPATIBLE_DR:-}" != '1' ]]
  exit
fi
if [[ " $* " == *' -d -r- '* ]]; then
  requirement_prefix='# '
  [[ "${VOX_TEST_REQUIREMENT_PREFIX:-}" != normal ]] || requirement_prefix=''
  printf '%sdesignated => identifier "com.ryumizu.vox" and anchor apple generic\n' \
    "$requirement_prefix" >&2
  exit 0
fi
exec /usr/bin/codesign "$@"
SH
chmod +x "$temporary_root/bin/security" "$temporary_root/bin/codesign"

run_bundle() {
  PATH="$temporary_root/bin:$PATH" \
    VOX_DEVELOPMENT_SIGNING_CONFIG="$temporary_root/development-signing-identity" \
    VOX_TEST_IDENTITY_AVAILABLE="${VOX_TEST_IDENTITY_AVAILABLE:-}" \
    VOX_TEST_IDENTITY_NAME="${VOX_TEST_IDENTITY_NAME:-}" \
    VOX_TEST_FINGERPRINT="$fingerprint" VOX_TEST_SIGNING_LOG="$signing_log" \
    VOX_TEST_SIGNING_FAILURE="${VOX_TEST_SIGNING_FAILURE:-}" \
    VOX_TEST_INCOMPATIBLE_DR="${VOX_TEST_INCOMPATIBLE_DR:-}" \
    VOX_TEST_REQUIREMENT_PREFIX="${VOX_TEST_REQUIREMENT_PREFIX:-}" \
    "$fixture_root/scripts/bundle-app" --development --binary "$temporary_root/Vox" \
      --icon "$temporary_root/AppIcon.png" --allow-dirty "$@"
}

run_entrypoint() {
  PATH="$temporary_root/bin:$PATH" \
    VOX_DEVELOPMENT_SIGNING_CONFIG="$temporary_root/missing-entrypoint-identity" \
    VOX_TEST_FINGERPRINT="$fingerprint" VOX_TEST_SIGNING_LOG="$signing_log" \
    "$fixture_root/scripts/bundle-app" --binary "$temporary_root/Vox" \
      --icon "$temporary_root/AppIcon.png" --allow-dirty "$@"
}

if run_entrypoint --output "$temporary_root/bare-default.app" >"$temporary_root/bare.out" 2>&1; then
  fail 'bare bundle-app invocation did not default to development signing'
fi
grep -Fq 'development signing configuration' "$temporary_root/bare.out" \
  || fail 'bare bundle-app failure did not explain the missing development configuration'
run_entrypoint --adhoc --output "$temporary_root/explicit-adhoc.app"
[[ -d "$temporary_root/explicit-adhoc.app" ]] \
  || fail 'explicit ad-hoc mode did not create a candidate without development configuration'
if run_entrypoint --adhoc --development --output "$temporary_root/conflicting-mode.app" \
  >"$temporary_root/conflicting.out" 2>&1; then
  fail 'bundle-app accepted conflicting signing modes'
fi

if run_bundle --output "$temporary_root/missing-config.app" >"$temporary_root/missing.out" 2>&1; then
  fail 'development signing succeeded without configuration'
fi
printf 'not-a-fingerprint\n' >"$temporary_root/development-signing-identity"
if run_bundle --output "$temporary_root/malformed-config.app" >"$temporary_root/malformed.out" 2>&1; then
  fail 'development signing accepted malformed configuration'
fi
printf '%s extra\n' "$fingerprint" >"$temporary_root/development-signing-identity"
if run_bundle --output "$temporary_root/whitespace-config.app" >"$temporary_root/whitespace.out" 2>&1; then
  fail 'development signing accepted embedded whitespace'
fi
printf '%s\n' "$fingerprint" >"$temporary_root/development-signing-identity"
if run_bundle --output "$temporary_root/unavailable.app" >"$temporary_root/unavailable.out" 2>&1; then
  fail 'development signing accepted an unavailable certificate'
fi
if VOX_TEST_IDENTITY_AVAILABLE=1 \
  VOX_TEST_IDENTITY_NAME='Developer ID Application: Apple Development: Fixture' \
  run_bundle --output "$temporary_root/wrong-category.app" >"$temporary_root/wrong-category.out" 2>&1; then
  fail 'development signing accepted a differently typed certificate'
fi

VOX_TEST_IDENTITY_AVAILABLE=1 run_bundle
development_app="$fixture_root/dist/Vox-1.0.0.app"
[[ -d "$development_app" ]] || fail 'stable development candidate is missing'
grep -Fqx 'candidate: local-development' "$development_app/Contents/Resources/BUILD-INFO.txt" \
  || fail 'development candidate metadata is missing'
grep -Fqx "signing certificate sha1: $fingerprint" \
  "$development_app/Contents/Resources/BUILD-INFO.txt" || fail 'signing fingerprint metadata is missing'
[[ "$(grep -Fc -- "--sign $fingerprint" "$signing_log")" == '2' ]] \
  || fail 'configured identity was not forwarded to both signature passes'

requirement_dump="$(/usr/bin/codesign -d -r- "$development_app" 2>&1)"
printf '%s\n' "$requirement_dump" \
  | sed -n -e 's/^# designated => //p' -e 's/^designated => //p' \
  >"$temporary_root/self.requirement"
/usr/bin/codesign -v --strict -R "$temporary_root/self.requirement" "$development_app" \
  || fail 'normalized designated requirement failed against its own ad-hoc fixture'
cp -R "$development_app" "$temporary_root/different.app"
cat >"$temporary_root/different.c" <<'C'
int main(void) { return 0; }
C
cc "$temporary_root/different.c" -o "$temporary_root/different.app/Contents/MacOS/Vox"
/usr/bin/codesign --sign - --force --options runtime \
  --entitlements "$fixture_root/Resources/App/Vox.entitlements" "$temporary_root/different.app"
if /usr/bin/codesign -v --strict -R "$temporary_root/self.requirement" \
  "$temporary_root/different.app" >/dev/null 2>&1; then
  fail 'ad-hoc designated requirement accepted a different signed binary'
fi

awk '/^bundle:$/ { inside = 1; next }
     inside && /^[^ \t]/ { inside = 0 }
     inside && /scripts\/bundle-app --development --allow-dirty/ { found = 1 }
     END { exit !found }' \
  "$project_root/justfile" || fail 'just bundle does not use the configured development identity'

prior_digest="$(shasum -a 256 "$development_app/Contents/Resources/BUILD-INFO.txt" | awk '{print $1}')"
if VOX_TEST_IDENTITY_AVAILABLE=1 VOX_TEST_SIGNING_FAILURE=1 run_bundle \
  >"$temporary_root/signing-failure.out" 2>&1; then
  fail 'synthetic signing failure succeeded'
fi
[[ "$(shasum -a 256 "$development_app/Contents/Resources/BUILD-INFO.txt" | awk '{print $1}')" == "$prior_digest" ]] \
  || fail 'signing failure changed the prior development candidate'

if VOX_TEST_IDENTITY_AVAILABLE=1 VOX_TEST_INCOMPATIBLE_DR=1 \
  VOX_TEST_REQUIREMENT_PREFIX=normal run_bundle \
  >"$temporary_root/incompatible-dr.out" 2>&1; then
  fail 'incompatible designated requirements were accepted'
fi
[[ "$(shasum -a 256 "$development_app/Contents/Resources/BUILD-INFO.txt" | awk '{print $1}')" == "$prior_digest" ]] \
  || fail 'incompatible DR changed the prior development candidate'

printf 'Development signing tests: passed\n'
