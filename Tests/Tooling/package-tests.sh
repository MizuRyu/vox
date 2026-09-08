#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/vox-package-tests.XXXXXX")"
sleeper_pid=""
cleanup() {
  if [[ -n "$sleeper_pid" ]]; then
    kill "$sleeper_pid" 2>/dev/null || true
    wait "$sleeper_pid" 2>/dev/null || true
  fi
  rm -rf "$temporary_root"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cc "$project_root/Tests/Tooling/sleeper.c" -o "$temporary_root/Vox"
source_png="$project_root/images/settings.png"
sips -c 1024 1024 "$source_png" --out "$temporary_root/AppIcon.png" >/dev/null

app="$temporary_root/Vox-local-adhoc.app"
"$project_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" --icon "$temporary_root/AppIcon.png" \
  --output "$app" --allow-dirty
"$project_root/scripts/validate-app" "$app"
[[ "$(plutil -extract LSUIElement raw "$app/Contents/Info.plist")" == 'false' ]] \
  || fail 'packaged app is hidden from the Dock'
accessory_app="$temporary_root/legacy-accessory.app"
cp -R "$app" "$accessory_app"
plutil -replace LSUIElement -bool true "$accessory_app/Contents/Info.plist"
codesign --sign - --force --options runtime \
  --entitlements "$project_root/Resources/App/Vox.entitlements" "$accessory_app" >/dev/null
if "$project_root/scripts/validate-app" "$accessory_app" >"$temporary_root/accessory-default.out" 2>&1; then
  fail 'Dock-hidden app passed strict validation'
fi
grep -Fq 'LSUIElement must be false' "$temporary_root/accessory-default.out" \
  || fail 'Dock-hidden fixture did not reach the LSUIElement check'
"$project_root/scripts/validate-app" --allow-accessory "$accessory_app"
[[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == 'local.vox.app' ]] \
  || fail 'bundle identifier differs from resident app identity'
[[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == '1.0.0' ]] \
  || fail 'short version is incorrect'
[[ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" == '1.0.0' ]] \
  || fail 'bundle version is incorrect'
grep -Fq 'candidate: local-adhoc' "$app/Contents/Resources/BUILD-INFO.txt" \
  || fail 'local candidate label is missing'
grep -Fq 'provenance: custom-binary-unverified' "$app/Contents/Resources/BUILD-INFO.txt" \
  || fail 'custom binary is not marked unverified'
cp "$app/Contents/MacOS/Vox" "$temporary_root/unsigned-Vox"
codesign --remove-signature "$temporary_root/unsigned-Vox"
binary_digest="$(shasum -a 256 "$temporary_root/unsigned-Vox" | awk '{print $1}')"
grep -Fq "binary unsigned sha256: $binary_digest" "$app/Contents/Resources/BUILD-INFO.txt" \
  || fail 'bundled binary digest is missing or incorrect'
if "$project_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" --icon "$temporary_root/AppIcon.png" \
  --output "$app" --allow-dirty >"$temporary_root/overwrite.out" 2>&1; then
  fail 'existing app was overwritten'
fi

# Exercise stable default output behavior in an isolated checkout so the real
# repository dist directory is never touched.
fixture_root="$temporary_root/project"
mkdir -p "$fixture_root/scripts" "$fixture_root/Resources/App"
cp "$project_root/scripts/bundle-app" "$project_root/scripts/make-app-icon" \
  "$project_root/scripts/make-dmg" "$project_root/scripts/validate-app" "$fixture_root/scripts/"
cp "$project_root/Resources/App/Info.plist" "$project_root/Resources/App/Vox.entitlements" \
  "$fixture_root/Resources/App/"
printf '1.0.0\n' >"$fixture_root/VERSION"
git -C "$fixture_root" init -q
git -C "$fixture_root" add .
git -C "$fixture_root" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
"$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty
stable_app="$fixture_root/dist/Vox-1.0.0.app"
[[ -d "$stable_app" ]] || fail 'stable default app output is missing'
plutil -replace LSUIElement -bool true "$stable_app/Contents/Info.plist"
codesign --sign - --force --options runtime \
  --entitlements "$fixture_root/Resources/App/Vox.entitlements" "$stable_app" >/dev/null
if "$fixture_root/scripts/validate-app" "$stable_app" >"$temporary_root/build5-default.out" 2>&1; then
  fail 'build5-style accessory app passed strict validation'
fi
"$fixture_root/scripts/validate-app" --allow-accessory "$stable_app"
"$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty
[[ "$(plutil -extract LSUIElement raw "$stable_app/Contents/Info.plist")" == 'false' ]] \
  || fail 'build5-style accessory app was not replaced by a Dock-visible candidate'
stable_digest="$(shasum -a 256 "$stable_app/Contents/Resources/BUILD-INFO.txt" | awk '{print $1}')"
if "$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/missing-Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty >"$temporary_root/app-failure.out" 2>&1; then
  fail 'missing candidate executable was accepted'
fi
[[ "$(shasum -a 256 "$stable_app/Contents/Resources/BUILD-INFO.txt" | awk '{print $1}')" == "$stable_digest" ]] \
  || fail 'failed app candidate changed the prior stable app'

saved_stable_app="$temporary_root/saved-stable.app"
mv "$stable_app" "$saved_stable_app"
mkdir "$stable_app"
printf 'unrelated\n' >"$stable_app/README"
if "$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty >"$temporary_root/unrelated-app.out" 2>&1; then
  fail 'unrelated default output directory was overwritten'
fi
[[ -f "$stable_app/README" ]] || fail 'unrelated default output directory was changed'
rm -rf "$stable_app"
mv "$saved_stable_app" "$stable_app"

cp -R "$stable_app" "$saved_stable_app"
plutil -replace CFBundleShortVersionString -string 9.9.9 "$stable_app/Contents/Info.plist"
codesign --sign - --force --options runtime \
  --entitlements "$fixture_root/Resources/App/Vox.entitlements" "$stable_app" >/dev/null
if "$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty >"$temporary_root/wrong-version-app.out" 2>&1; then
  fail 'existing app with the wrong version was overwritten'
fi
[[ "$(plutil -extract CFBundleShortVersionString raw "$stable_app/Contents/Info.plist")" == '9.9.9' ]] \
  || fail 'wrong-version app was changed during refusal'
rm -rf "$stable_app"
mv "$saved_stable_app" "$stable_app"

cp -R "$stable_app" "$saved_stable_app"
sed 's/^Developer ID signed: no$/Developer ID signed: yes/' \
  "$stable_app/Contents/Resources/BUILD-INFO.txt" >"$temporary_root/signed-build-info"
cp "$temporary_root/signed-build-info" "$stable_app/Contents/Resources/BUILD-INFO.txt"
codesign --sign - --force --options runtime \
  --entitlements "$fixture_root/Resources/App/Vox.entitlements" "$stable_app" >/dev/null
if "$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty >"$temporary_root/signed-local-app.out" 2>&1; then
  fail 'Developer ID marker at the stable local path was overwritten'
fi
grep -Fqx 'Developer ID signed: yes' "$stable_app/Contents/Resources/BUILD-INFO.txt" \
  || fail 'Developer ID marked app was changed during refusal'
rm -rf "$stable_app"
mv "$saved_stable_app" "$stable_app"

"$stable_app/Contents/MacOS/Vox" &
sleeper_pid="$!"
if "$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty >"$temporary_root/running-app.out" 2>&1; then
  fail 'running default app executable was overwritten'
fi
[[ "$(shasum -a 256 "$stable_app/Contents/Resources/BUILD-INFO.txt" | awk '{print $1}')" == "$stable_digest" ]] \
  || fail 'running default app changed during refusal'
kill "$sleeper_pid"
wait "$sleeper_pid" 2>/dev/null || true
sleeper_pid=""

fake_ps="$temporary_root/failing-ps"
mkdir "$fake_ps"
printf '#!/usr/bin/env bash\nexit 42\n' >"$fake_ps/ps"
chmod +x "$fake_ps/ps"
if PATH="$fake_ps:$PATH" "$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty >"$temporary_root/process-inspection.out" 2>&1; then
  fail 'default app replacement proceeded after process inspection failed'
fi
[[ "$(shasum -a 256 "$stable_app/Contents/Resources/BUILD-INFO.txt" | awk '{print $1}')" == "$stable_digest" ]] \
  || fail 'process inspection failure changed the prior stable app'

mv "$fixture_root/dist" "$fixture_root/real-dist"
ln -s "$fixture_root/real-dist" "$fixture_root/dist"
if "$fixture_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --allow-dirty >"$temporary_root/dist-symlink.out" 2>&1; then
  fail 'symbolic-link default output directory was accepted'
fi
[[ -L "$fixture_root/dist" ]] || fail 'symbolic-link default output directory was changed'
rm "$fixture_root/dist"
mv "$fixture_root/real-dist" "$fixture_root/dist"

stable_dmg="$fixture_root/dist/Vox-1.0.0.dmg"
"$fixture_root/scripts/make-dmg" "$stable_app" "$stable_dmg"
"$fixture_root/scripts/make-dmg" "$stable_app" "$stable_dmg"
(cd "$fixture_root/dist" && shasum -a 256 -c "$(basename "$stable_dmg.sha256")")

stable_dmg_digest="$(shasum -a 256 "$stable_dmg" | awk '{print $1}')"
stable_checksum_digest="$(shasum -a 256 "$stable_dmg.sha256" | awk '{print $1}')"
cp -R "$stable_app" "$saved_stable_app"
sed 's/^notarization ticket stapled to this app: no$/notarization ticket stapled to this app: yes/' \
  "$stable_app/Contents/Resources/BUILD-INFO.txt" >"$temporary_root/stapled-build-info"
cp "$temporary_root/stapled-build-info" "$stable_app/Contents/Resources/BUILD-INFO.txt"
codesign --sign - --force --options runtime \
  --entitlements "$fixture_root/Resources/App/Vox.entitlements" "$stable_app" >/dev/null
if "$fixture_root/scripts/make-dmg" "$stable_app" "$stable_dmg" \
  >"$temporary_root/stapled-local-dmg.out" 2>&1; then
  fail 'stapled marker authorized stable local DMG replacement'
fi
[[ "$(shasum -a 256 "$stable_dmg" | awk '{print $1}')" == "$stable_dmg_digest" ]] \
  || fail 'stapled-marker refusal changed the stable DMG'
[[ "$(shasum -a 256 "$stable_dmg.sha256" | awk '{print $1}')" == "$stable_checksum_digest" ]] \
  || fail 'stapled-marker refusal changed the stable checksum'
rm -rf "$stable_app"
mv "$saved_stable_app" "$stable_app"

fake_hdiutil="$temporary_root/failing-hdiutil"
mkdir "$fake_hdiutil"
printf '#!/usr/bin/env bash\nexit 42\n' >"$fake_hdiutil/hdiutil"
chmod +x "$fake_hdiutil/hdiutil"
stable_dmg_digest="$(shasum -a 256 "$stable_dmg" | awk '{print $1}')"
stable_checksum_digest="$(shasum -a 256 "$stable_dmg.sha256" | awk '{print $1}')"
if PATH="$fake_hdiutil:$PATH" "$fixture_root/scripts/make-dmg" "$stable_app" "$stable_dmg" \
  >"$temporary_root/default-dmg-failure.out" 2>&1; then
  fail 'failing hdiutil unexpectedly replaced the stable DMG'
fi
[[ "$(shasum -a 256 "$stable_dmg" | awk '{print $1}')" == "$stable_dmg_digest" ]] \
  || fail 'failed default DMG candidate changed the prior DMG'
[[ "$(shasum -a 256 "$stable_dmg.sha256" | awk '{print $1}')" == "$stable_checksum_digest" ]] \
  || fail 'failed default DMG candidate changed the prior checksum'

swapping_hdiutil="$temporary_root/swapping-hdiutil"
mkdir "$swapping_hdiutil"
cat >"$swapping_hdiutil/hdiutil" <<'SH'
#!/usr/bin/env bash
/usr/bin/hdiutil "$@" || exit "$?"
/bin/mv "$TEST_DIST" "$TEST_SAVED_DIST"
/bin/cp -R "$TEST_SAVED_DIST" "$TEST_OUTSIDE_DIST"
/bin/ln -s "$TEST_OUTSIDE_DIST" "$TEST_DIST"
SH
chmod +x "$swapping_hdiutil/hdiutil"
saved_dist="$fixture_root/saved-dist"
outside_dist="$temporary_root/outside-dist"
if TEST_DIST="$fixture_root/dist" TEST_SAVED_DIST="$saved_dist" TEST_OUTSIDE_DIST="$outside_dist" \
  PATH="$swapping_hdiutil:$PATH" "$fixture_root/scripts/make-dmg" "$stable_app" "$stable_dmg" \
  >"$temporary_root/dmg-parent-swap.out" 2>&1; then
  fail 'DMG publication accepted a replaced output parent'
fi
[[ "$(shasum -a 256 "$outside_dist/Vox-1.0.0.dmg" | awk '{print $1}')" == "$stable_dmg_digest" ]] \
  || fail 'DMG publication changed the redirected outside target'
rm "$fixture_root/dist"
rm -rf "$outside_dist"
mv "$saved_dist" "$fixture_root/dist"

fake_mv="$temporary_root/failing-mv"
mkdir "$fake_mv"
cat >"$fake_mv/mv" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == */.vox-dmg.*/* && "$(basename "$1")" == 'Vox-1.0.0.dmg.sha256' ]]; then
  exit 91
fi
exec /bin/mv "$@"
SH
chmod +x "$fake_mv/mv"
if PATH="$fake_mv:$PATH" "$fixture_root/scripts/make-dmg" "$stable_app" "$stable_dmg" \
  >"$temporary_root/checksum-publish-failure.out" 2>&1; then
  fail 'failing checksum publication unexpectedly replaced the stable DMG pair'
fi
[[ "$(shasum -a 256 "$stable_dmg" | awk '{print $1}')" == "$stable_dmg_digest" ]] \
  || fail 'checksum publication failure did not restore the prior DMG'
[[ "$(shasum -a 256 "$stable_dmg.sha256" | awk '{print $1}')" == "$stable_checksum_digest" ]] \
  || fail 'checksum publication failure did not restore the prior checksum'

literal_app="$temporary_root/literal \$(touch SHOULD-NOT-EXIST).app"
literal_dmg="$temporary_root/literal \$(touch SHOULD-NOT-EXIST).dmg"
cp -R "$stable_app" "$literal_app"
"$fixture_root/scripts/make-dmg" "$literal_app" "$literal_dmg"
[[ -f "$literal_dmg" && ! -e "$fixture_root/SHOULD-NOT-EXIST" ]] \
  || fail 'custom DMG path with literal metacharacters was not preserved'
fresh_fixture="$temporary_root/fresh-project"
mkdir -p "$fresh_fixture/scripts"
cp "$project_root/scripts/make-dmg" "$project_root/scripts/validate-app" "$fresh_fixture/scripts/"
cp "$project_root/VERSION" "$fresh_fixture/VERSION"
fresh_custom_dmg="$temporary_root/fresh-custom.dmg"
"$fresh_fixture/scripts/make-dmg" "$app" "$fresh_custom_dmg"
[[ -f "$fresh_custom_dmg" && ! -e "$fresh_fixture/dist" ]] \
  || fail 'custom DMG creation in a checkout without dist failed or created dist'

cp -R "$app" "$temporary_root/leaky.app"
printf '/Users/example/source\n' >>"$temporary_root/leaky.app/Contents/Resources/BUILD-INFO.txt"
codesign --sign - --force --options runtime \
  --entitlements "$project_root/Resources/App/Vox.entitlements" "$temporary_root/leaky.app" >/dev/null
if "$project_root/scripts/validate-app" "$temporary_root/leaky.app" >"$temporary_root/leak.out" 2>&1; then
  fail 'private source path was accepted'
fi
grep -Fq 'private absolute user path' "$temporary_root/leak.out" \
  || fail 'privacy fixture did not reach the private-path check'
cp -R "$app" "$temporary_root/digest-mismatch.app"
python3 - "$temporary_root/digest-mismatch.app/Contents/MacOS/Vox" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = bytearray(path.read_bytes())
payload[4096] ^= 1
path.write_bytes(payload)
PY
codesign --sign - --force --options runtime \
  --entitlements "$project_root/Resources/App/Vox.entitlements" "$temporary_root/digest-mismatch.app" >/dev/null
if "$project_root/scripts/validate-app" "$temporary_root/digest-mismatch.app" \
  >"$temporary_root/digest.out" 2>&1; then
  fail 'changed binary was accepted with a stale digest'
fi
grep -Fq 'binary digest does not match' "$temporary_root/digest.out" \
  || fail 'binary digest mismatch was not diagnosed'
if VOX_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  "$project_root/scripts/sign-app" "$app" "$temporary_root/signed.app" >"$temporary_root/sign.out" 2>&1; then
  fail 'custom binary provenance was accepted for Developer ID signing'
fi
grep -Fq 'custom binary provenance' "$temporary_root/sign.out" \
  || fail 'custom binary signing rejection was not diagnosed'
if VOX_SIGNING_IDENTITY='-' "$project_root/scripts/sign-app" "$app" \
  "$temporary_root/arbitrary-signed.app" >"$temporary_root/identity.out" 2>&1; then
  fail 'an arbitrary signing identity was accepted'
fi
grep -Fq 'Developer ID Application identity' "$temporary_root/identity.out" \
  || fail 'arbitrary signing identity rejection was not diagnosed'
ln -s "$temporary_root/missing-output" "$temporary_root/dangling.app"
if "$project_root/scripts/bundle-app" --adhoc --binary "$temporary_root/Vox" \
  --icon "$temporary_root/AppIcon.png" --output "$temporary_root/dangling.app" --allow-dirty \
  >"$temporary_root/dangling.out" 2>&1; then
  fail 'dangling app output symlink was overwritten'
fi
[[ -L "$temporary_root/dangling.app" ]] || fail 'dangling app output symlink was replaced'
if VOX_NOTARY_PROFILE='' VOX_SIGNING_IDENTITY='' "$project_root/scripts/notarize-dmg" \
  "$temporary_root/missing.dmg" "$temporary_root/notarized.dmg" \
  >"$temporary_root/notary.out" 2>&1; then
  fail 'notarization ran without a keychain profile'
fi
dmg="$temporary_root/Vox-local-adhoc.dmg"
"$project_root/scripts/make-dmg" "$app" "$dmg"
[[ -f "$dmg" && -f "$dmg.sha256" ]] || fail 'DMG outputs are missing'
(cd "$temporary_root" && shasum -a 256 -c "$(basename "$dmg.sha256")")
if "$project_root/scripts/make-dmg" "$app" "$dmg" >"$temporary_root/dmg-overwrite.out" 2>&1; then
  fail 'existing DMG was overwritten'
fi
ln -s "$temporary_root/missing-dmg" "$temporary_root/dangling.dmg"
if "$project_root/scripts/make-dmg" "$app" "$temporary_root/dangling.dmg" \
  >"$temporary_root/dmg-symlink.out" 2>&1; then
  fail 'dangling DMG output symlink was overwritten'
fi

# Exercise a well-formed but wrong revision independently of the developer checkout.
revision_app="$temporary_root/wrong-revision.app"
cp -R "$app" "$revision_app"
sed -e 's/^provenance: .*/provenance: verified-clean-build/' \
  -e 's/^source revision: .*/source revision: 1111111111111111111111111111111111111111/' \
  "$revision_app/Contents/Resources/BUILD-INFO.txt" >"$temporary_root/revision-info"
cp "$temporary_root/revision-info" "$revision_app/Contents/Resources/BUILD-INFO.txt"
codesign --sign - --force --options runtime \
  --entitlements "$project_root/Resources/App/Vox.entitlements" "$revision_app" >/dev/null
fake_git="$temporary_root/fake-git"
mkdir "$fake_git"
cat >"$fake_git/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'status --porcelain'*) exit 0 ;;
  *'rev-parse --verify HEAD'*) printf '2222222222222222222222222222222222222222\n' ;;
  *) exit 77 ;;
esac
SH
chmod +x "$fake_git/git"
if PATH="$fake_git:$PATH" VOX_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  "$project_root/scripts/sign-app" "$revision_app" "$temporary_root/wrong-signed.app" \
  >"$temporary_root/revision.out" 2>&1; then
  fail 'well-formed wrong revision was accepted'
fi
grep -Fq 'source revision does not match checkout HEAD' "$temporary_root/revision.out" \
  || fail 'revision fixture did not reach the HEAD check'

fake_bin="$temporary_root/fake-bin"
mkdir "$fake_bin"
cat >"$fake_bin/security" <<'SH'
#!/usr/bin/env bash
printf '  1) FIXTURE "Developer ID Application: Fixture"\n'
SH
cat >"$fake_bin/codesign" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$fake_bin/spctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fake_bin/security" "$fake_bin/codesign" "$fake_bin/xcrun" "$fake_bin/spctl"
notary_input_digest="$(shasum -a 256 "$dmg" | awk '{print $1}')"
notarized="$temporary_root/Vox-notarized.dmg"
PATH="$fake_bin:$PATH" VOX_NOTARY_PROFILE='fixture-profile' \
  VOX_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  "$project_root/scripts/notarize-dmg" "$dmg" "$notarized"
[[ "$(shasum -a 256 "$dmg" | awk '{print $1}')" == "$notary_input_digest" ]] \
  || fail 'notarization changed its input DMG'
[[ -f "$notarized" && -f "$notarized.sha256" ]] || fail 'notarized outputs are missing'
(cd "$temporary_root" && shasum -a 256 -c "$(basename "$notarized.sha256")")
ln -s "$temporary_root/missing-notarized" "$temporary_root/dangling-notarized.dmg"
if PATH="$fake_bin:$PATH" VOX_NOTARY_PROFILE='fixture-profile' \
  VOX_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  "$project_root/scripts/notarize-dmg" "$dmg" "$temporary_root/dangling-notarized.dmg" \
  >"$temporary_root/notary-symlink.out" 2>&1; then
  fail 'dangling notarized output symlink was overwritten'
fi
printf 'Package tests: passed\n'
