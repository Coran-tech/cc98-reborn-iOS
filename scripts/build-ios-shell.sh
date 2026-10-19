#!/usr/bin/env bash
# One build path for GitHub Actions and Codemagic. No signing or distribution.
set -euo pipefail

DEVICE_ONLY=false
if [[ $# -eq 1 && "$1" == --device-only ]]; then
  DEVICE_ONLY=true
elif [[ $# -ne 0 ]]; then
  echo 'Usage: bash scripts/build-ios-shell.sh [--device-only]' >&2
  exit 2
fi
BUILD_MODE=full
OAUTH_PROTOCOL_VALIDATION=not_run
SIMULATOR_VALIDATION=not_run
DEVICE_PACKAGE=not_produced
CANDIDATE_NAME=CC98RebornShell-unsigned-device.ipa
if [[ "$DEVICE_ONLY" == true ]]; then
  BUILD_MODE=device-only
  SIMULATOR_VALIDATION=skipped_device_only
  CANDIDATE_NAME=CC98RebornShell-unsigned-unverified-device.ipa
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This build requires macOS with Xcode 26.0.1; use the cloud workflow." >&2
  exit 1
fi

mkdir -p "$ROOT/build/ios-shell"
RUN_DIR="$(mktemp -d "$ROOT/build/ios-shell/run.XXXXXX")"
ARTIFACTS="$RUN_DIR/artifacts"
mkdir -p "$ARTIFACTS"
exec > >(tee "$ARTIFACTS/build.log") 2>&1
PROJECT="$ROOT/ios/CC98RebornShell.xcodeproj"
SCHEME=CC98RebornShell
TEST_RESULTS="$ARTIFACTS/simulator-tests.xcresult"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-${BUILD_NUMBER:-1}}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Build number must be a positive integer." >&2; exit 1; }

run_with_timeout() {
  # Bound only this command's process group, never global Simulator services.
  python3 - "$@" <<'PY'
import os, signal, subprocess, sys
seconds = int(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    sys.exit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    print("[watchdog] timeout after %ss: %s" % (seconds, sys.argv[2]), flush=True)
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    # Also close any owned child that outlived the xcodebuild/simctl process.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    sys.exit(124)
PY
}

finish() {
  local status=$?
  if [[ "$OAUTH_PROTOCOL_VALIDATION" == running ]]; then OAUTH_PROTOCOL_VALIDATION=failed_or_incomplete; fi
  if [[ "$SIMULATOR_VALIDATION" == running ]]; then SIMULATOR_VALIDATION=failed_or_incomplete; fi
  # Installation can fail after compilation. Preserve only the built app's plist,
  # not a simulator data container or any website/session data.
  local simulator_plist="$RUN_DIR/simulator-derived-data/Build/Products/Debug-iphonesimulator/CC98RebornShell.app/Info.plist"
  if [[ -f "$simulator_plist" ]]; then
    if ! cp "$simulator_plist" "$ARTIFACTS/simulator-app-Info.plist"; then
      echo "Could not retain the compiled simulator app Info.plist." >&2
    fi
  fi
  if [[ -n "${SIMULATOR_UDID:-}" ]]; then
    if ! run_with_timeout 30 xcrun simctl list devices --json > "$ARTIFACTS/simulator-state-on-exit.json" 2> "$ARTIFACTS/simulator-state-on-exit.log"; then
      echo "Could not collect Simulator state within 30 seconds." >&2
    fi
  fi
  # Preserve attachments from a failed test run as well as its xcresult/log.
  if [[ -d "$TEST_RESULTS" && ! -d "$ARTIFACTS/screenshots" ]]; then
    run_with_timeout 60 xcrun xcresulttool export attachments --path "$TEST_RESULTS" \
      --output-path "$ARTIFACTS/screenshots" > "$ARTIFACTS/attachment-export.log" 2>&1 || true
  fi
  printf 'exit_code=%s\nbuild_mode=%s\noauth_protocol_validation=%s\nsimulator_validation=%s\ndevice_package=%s\n' \
    "$status" "$BUILD_MODE" "$OAUTH_PROTOCOL_VALIDATION" "$SIMULATOR_VALIDATION" "$DEVICE_PACKAGE" > "$ARTIFACTS/build-status.txt"
  echo "Build evidence: $ARTIFACTS"
  exit "$status"
}
trap finish EXIT

for tool in node python3 xcodebuild xcrun ditto curl; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
xcodebuild -version | tee "$ARTIFACTS/xcode-version.txt"
grep -Fxq 'Xcode 26.0.1' "$ARTIFACTS/xcode-version.txt" || {
  echo "Select stable Xcode 26.0.1; this workflow does not silently change toolchains." >&2
  exit 1
}
# Official release layout includes bin/ and share/xcodegen/SettingPresets.
# https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0
mkdir -p "$RUN_DIR/tools"
curl --fail --location --retry 3 \
  'https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip' \
  --output "$RUN_DIR/tools/xcodegen.zip"
ditto -x -k "$RUN_DIR/tools/xcodegen.zip" "$RUN_DIR/tools"
XCODEGEN="$RUN_DIR/tools/xcodegen/bin/xcodegen"
test -x "$XCODEGEN"
"$XCODEGEN" --version | tee "$ARTIFACTS/xcodegen-version.txt"
grep -Eq '(^|[[:space:]])2\.46\.0$' "$ARTIFACTS/xcodegen-version.txt"
node --version
if command -v shellcheck >/dev/null; then
  shellcheck scripts/build-ios-shell.sh
else
  echo "shellcheck unavailable; running bash syntax check."
fi
bash -n scripts/build-ios-shell.sh
node --test tests/ios-*.test.cjs 2>&1 | tee "$ARTIFACTS/node-tests.log"

# BEGIN OAUTH_PROTOCOL_VALIDATION
# Compile the production protocol/storage sources, not a test-side reimplementation.
# This host-side check is mandatory in both modes and never starts a Simulator.
echo '=== Production OAuth protocol tests (macOS, no Simulator) ==='
OAUTH_PROTOCOL_VALIDATION=running
run_with_timeout 120 xcrun --sdk macosx swiftc -D OAUTH_PROTOCOL_HARNESS \
  ios/CC98RebornShell/OAuthProtocol.swift \
  ios/CC98RebornShell/OAuthHTTPClient.swift \
  ios/CC98RebornShell/ShellPolicy.swift \
  ios/CC98RebornShell/LocalSettingsStore.swift \
  ios/CC98RebornShellTests/OAuthProtocolHarness.swift \
  -o "$RUN_DIR/reborn-oauth-tests" \
  2>&1 | tee "$ARTIFACTS/oauth-protocol-compile.log"
run_with_timeout 30 "$RUN_DIR/reborn-oauth-tests" \
  2>&1 | tee "$ARTIFACTS/oauth-protocol-tests.log"
OAUTH_PROTOCOL_VALIDATION=passed
# END OAUTH_PROTOCOL_VALIDATION

# Resources must exist before XcodeGen resolves the folder reference.
node scripts/package-ios-resources.cjs
"$XCODEGEN" generate --spec ios/project.yml --project ios
test -d "$PROJECT"

# BEGIN FULL_SIMULATOR_VALIDATION
if [[ "$DEVICE_ONLY" == false ]]; then
# Narrow identity evidence for the observed simulator 'Missing bundle ID' failure.
python3 - <<'PY' | tee "$ARTIFACTS/source-plist-identity.json"
import json, plistlib
with open("ios/CC98RebornShell/Info.plist", "rb") as source:
    info = plistlib.load(source)
keys = ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleName", "CFBundlePackageType", "CFBundleShortVersionString", "CFBundleVersion")
print(json.dumps({key: info.get(key) for key in keys}, indent=2))
PY
xcodebuild -showBuildSettings -json \
  -project "$PROJECT" -target "$SCHEME" -configuration Debug -sdk iphonesimulator \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  | python3 -c 'import json,sys; keys=("PRODUCT_BUNDLE_IDENTIFIER","INFOPLIST_FILE","INFOPLIST_PATH","GENERATE_INFOPLIST_FILE","INFOPLIST_KEY_CFBundleIdentifier","PRODUCT_NAME","EXECUTABLE_NAME","WRAPPER_NAME","CURRENT_PROJECT_VERSION"); print(json.dumps([{ "target": item.get("target"), "identity": {key: item.get("buildSettings",{}).get(key) for key in keys}} for item in json.load(sys.stdin)], indent=2))' \
  | tee "$ARTIFACTS/generated-build-identity.json"

# Simulator tests are evidence only, never the source of the device IPA.
# GitHub run 39146315001 lists this exact OS version; Xcode remains 26.0.1.
# A provider may explicitly override this only after checking its destinations.
SIMULATOR_DESTINATION="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 16,OS=26.0.1}"
printf '%s\n' "$SIMULATOR_DESTINATION" | tee "$ARTIFACTS/simulator-destination.txt"
echo '=== Simulator inventory and exact device selection ==='
run_with_timeout 30 xcrun simctl list runtimes --json > "$ARTIFACTS/simulator-runtimes.json"
run_with_timeout 30 xcrun simctl list devices available --json > "$ARTIFACTS/simulator-devices-before-boot.json"
# BEGIN SIMULATOR_SELECTOR
python3 - "$SIMULATOR_DESTINATION" "$ARTIFACTS/simulator-runtimes.json" "$ARTIFACTS/simulator-devices-before-boot.json" <<'PY' | tee "$ARTIFACTS/selected-simulator.json"
import json, sys, uuid
destination = dict(part.split("=", 1) for part in sys.argv[1].split(","))
assert destination.get("platform") == "iOS Simulator" and destination.get("name") and destination.get("OS"), "Use an exact iOS Simulator name and OS version"
with open(sys.argv[2]) as source:
    runtimes = json.load(source)["runtimes"]
with open(sys.argv[3]) as source:
    devices = json.load(source)["devices"]
matches = []
for runtime in runtimes:
    if not runtime.get("isAvailable") or runtime.get("version") != destination["OS"] or not runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
        continue
    for device in devices.get(runtime["identifier"], []):
        if device.get("isAvailable") and device.get("name") == destination["name"]:
            uuid.UUID(device["udid"])
            matches.append({"name": device["name"], "udid": device["udid"], "state": device["state"], "runtime": runtime["identifier"], "os": runtime["version"]})
assert len(matches) == 1, "Expected one available Simulator for %s; found %s" % (sys.argv[1], len(matches))
print(json.dumps(matches[0], indent=2))
PY
# END SIMULATOR_SELECTOR
SIMULATOR_UDID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["udid"])' "$ARTIFACTS/selected-simulator.json")"
SIMULATOR_STATE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$ARTIFACTS/selected-simulator.json")"
echo "=== Simulator boot: $SIMULATOR_UDID (initial state: $SIMULATOR_STATE) ==="
if [[ "$SIMULATOR_STATE" != Booted ]]; then
  run_with_timeout 60 xcrun simctl boot "$SIMULATOR_UDID" 2>&1 | tee "$ARTIFACTS/simulator-boot.log"
else
  echo 'Selected Simulator is already booted.' | tee "$ARTIFACTS/simulator-boot.log"
fi
run_with_timeout 180 xcrun simctl bootstatus "$SIMULATOR_UDID" -b 2>&1 | tee "$ARTIFACTS/simulator-bootstatus.log"
run_with_timeout 30 xcrun simctl list devices --json > "$ARTIFACTS/simulator-devices-after-boot.json"
echo "=== Simulator tests: $SIMULATOR_UDID (600s process watchdog, 120s maximum per test) ==="
SIMULATOR_VALIDATION=running
run_with_timeout 600 xcodebuild test \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -destination-timeout 120 \
  -derivedDataPath "$RUN_DIR/simulator-derived-data" \
  -resultBundlePath "$TEST_RESULTS" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$ARTIFACTS/simulator-tests.log"
SIMULATOR_VALIDATION=passed
run_with_timeout 60 xcrun xcresulttool export attachments --path "$TEST_RESULTS" \
  --output-path "$ARTIFACTS/screenshots" \
  2>&1 | tee "$ARTIFACTS/attachment-export.log"
else
  echo '=== DEVICE-ONLY: Simulator selection, boot and tests explicitly skipped; candidate remains unverified ==='
fi
# END FULL_SIMULATOR_VALIDATION

# Build an arm64 iPhoneOS app without a development team or signing identity.
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$RUN_DIR/device-derived-data" \
  -resultBundlePath "$ARTIFACTS/device-build.xcresult" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  2>&1 | tee "$ARTIFACTS/device-build.log"

APP="$RUN_DIR/device-derived-data/Build/Products/Release-iphoneos/CC98RebornShell.app"
test -d "$APP"
test -f "$APP/Info.plist"
test -f "$APP/CC98RebornShell"
test -d "$APP/Reborn"
test ! -e "$APP/Resources"
mkdir -p "$RUN_DIR/staging/Payload"
ditto "$APP" "$RUN_DIR/staging/Payload/CC98RebornShell.app"
# Package only Payload, not DerivedData, simulator products, sources or secrets.
ditto -c -k --norsrc --keepParent "$RUN_DIR/staging/Payload" "$RUN_DIR/candidate.zip"

# BEGIN IPA_VALIDATOR: also exercised with synthetic ZIPs by the Node contract test.
python3 - "$RUN_DIR/candidate.zip" <<'PY' | tee "$ARTIFACTS/ipa-validation.json"
import json
import pathlib
import plistlib
import stat
import struct
import sys
import zipfile

prefix = "Payload/CC98RebornShell.app/"
with zipfile.ZipFile(sys.argv[1]) as archive:
    entries = archive.infolist()
    names = [entry.orig_filename for entry in entries]
    assert names and len(names) == len(set(names)), "Empty ZIP or duplicate paths"
    for entry in entries:
        name = entry.orig_filename
        parts = pathlib.PurePosixPath(name).parts
        assert not name.startswith("/") and "\\" not in name, "Invalid ZIP path"
        assert ".." not in parts and "." not in name.split("/"), "ZIP traversal"
        assert name in ("Payload/", prefix) or name.startswith(prefix), "Unexpected ZIP member"
        assert name != prefix + "Resources" and not name.startswith(prefix + "Resources/"), "iOS app must not contain a top-level Resources directory"
        assert not stat.S_ISLNK(entry.external_attr >> 16), "Unexpected symlink"
    assert archive.testzip() is None, "Corrupt ZIP member"
    info = plistlib.loads(archive.read(prefix + "Info.plist"))
    assert info.get("CFBundleExecutable") == "CC98RebornShell", "Unexpected executable"
    assert info.get("CFBundleIdentifier") == "org.cc98.reborn.shell", "Unexpected bundle ID"
    assert info.get("CFBundlePackageType") == "APPL", "Not an application"
    assert info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Not an iPhoneOS app"
    assert info.get("DTPlatformName") == "iphoneos", "Simulator product rejected"
    minimum = tuple(int(part) for part in info.get("MinimumOSVersion", "0").split("."))
    assert minimum in ((17,), (17, 0)), "Deployment target must remain iOS 17.0"
    executable = archive.getinfo(prefix + "CC98RebornShell")
    assert (executable.external_attr >> 16) & 0o111, "Executable mode missing"
    binary = archive.read(executable)
    assert len(binary) >= 32, "Missing Mach-O header"
    magic, cpu, subtype, kind, count, command_size, flags, reserved = struct.unpack_from("<8I", binary)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C and kind == 2, "Expected thin arm64 executable"
    assert command_size <= len(binary) - 32, "Invalid load commands"
    offset, platforms = 32, []
    for _ in range(count):
        assert offset + 8 <= 32 + command_size, "Truncated load command"
        command, size = struct.unpack_from("<2I", binary, offset)
        assert size >= 8 and offset + size <= 32 + command_size, "Invalid load command size"
        if command == 0x32:  # LC_BUILD_VERSION; platform 2 = device iOS, 7 = simulator.
            assert size >= 24, "Truncated platform command"
            platforms.append(struct.unpack_from("<I", binary, offset + 8)[0])
        offset += size
    assert platforms == [2], "Mach-O is not built for iOS devices"
    resource_prefix = prefix + "Reborn/"
    index = json.loads(archive.read(resource_prefix + "manifest-index.json"))
    assert index.get("schemaVersion") == 1, "Unexpected resource index version"
    resources = []
    for group in ("pageScripts", "contentScripts", "styles", "assets"):
        assert isinstance(index.get(group), list), "Missing resource group"
        resources.extend(index[group])
    assert index["contentScripts"] and index["contentScripts"][0] == "runtime/ios-adapter.js", "Adapter must load first"
    assert index["styles"] and index["styles"][-1] == "runtime/ios-mobile.css", "Mobile CSS must load last"
    for resource in resources:
        assert isinstance(resource, str) and resource and not resource.startswith("/"), "Invalid resource path"
        assert "\\" not in resource and not any(part in ("", ".", "..") for part in resource.split("/")), "Unsafe resource path"
        assert resource_prefix + resource in names, "Missing indexed resource: " + resource
    for resource in ("src/page-submit-monitor.js", "src/topic-drawer.js", "src/content.js", "popup/popup.html", "src/content-filter-frame.html", "src/content-filter-frame.js", "src/content-filter-worker.js", "src/content-filter-core.js"):
        assert resource in resources, "Missing required runtime: " + resource
    for name in names:
        if name.startswith(resource_prefix) and not name.endswith("/"):
            resource = name[len(resource_prefix):]
            assert resource == "manifest-index.json" or resource in resources, "Unindexed bundled resource"
            assert resource not in ("manifest.json", "src/background.js", "src/semantic-background.js"), "Unexpected extension background"
    assert not any(name.endswith("embedded.mobileprovision") or "/_CodeSignature/" in name for name in names), "Expected an unsigned candidate"
    print(json.dumps({"bundleID": info["CFBundleIdentifier"], "platform": "iPhoneOS", "architecture": "arm64", "minimumOS": "17.0", "extensionVersion": index.get("extensionVersion"), "unsigned": True, "zipMembers": len(names), "indexedResources": len(resources)}, indent=2))
PY
# END IPA_VALIDATOR

printf '%s is a device candidate, NOT an install-ready signed app.\n' "$CANDIDATE_NAME" > "$ARTIFACTS/README.txt"
if [[ "$DEVICE_ONLY" == true ]]; then
  echo 'UNVERIFIED DEVICE-ONLY BUILD: Simulator selection, boot, unit tests and UI tests were NOT run. Successful packaging does not establish app launch or functionality.' >> "$ARTIFACTS/README.txt"
else
  echo 'Simulator tests passed. simulator-tests.xcresult and screenshots contain synthetic/offline evidence only.' >> "$ARTIFACTS/README.txt"
fi
cat >> "$ARTIFACTS/README.txt" <<'TXT'
It contains Payload/CC98RebornShell.app built for iPhoneOS arm64, minimum iOS 17.0.
Self-sign it locally with your chosen signing tool before installing on your iPhone.
No Apple account, provisioning profile, forum session or credentials were used by this build.
Passing cloud tests does not establish school/VPN connectivity, real login or physical-device acceptance.
TXT
# Both modes require Node and production OAuth checks, device build and ZIP/platform validation.
# The default mode additionally requires the full Simulator validation above.
mv "$RUN_DIR/candidate.zip" "$ARTIFACTS/$CANDIDATE_NAME"
DEVICE_PACKAGE=validated_unsigned
echo "Unsigned device candidate: $ARTIFACTS/$CANDIDATE_NAME"
