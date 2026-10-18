#!/usr/bin/env bash
# One build path for GitHub Actions and Codemagic. No signing or distribution.
set -euo pipefail

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

finish() {
  local status=$?
  # Preserve attachments from a failed test run as well as its xcresult/log.
  if [[ -d "$TEST_RESULTS" && ! -d "$ARTIFACTS/screenshots" ]]; then
    xcrun xcresulttool export attachments --path "$TEST_RESULTS" \
      --output-path "$ARTIFACTS/screenshots" > "$ARTIFACTS/attachment-export.log" 2>&1 || true
  fi
  printf 'exit_code=%s\n' "$status" > "$ARTIFACTS/build-status.txt"
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

# Resources must exist before XcodeGen resolves the folder reference.
node scripts/package-ios-resources.cjs
"$XCODEGEN" generate --spec ios/project.yml --project ios
test -d "$PROJECT"

# Simulator tests are evidence only, never the source of the device IPA.
# This runtime/device pair is installed in both pinned cloud images.
xcodebuild test \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.0' \
  -destination-timeout 120 \
  -derivedDataPath "$RUN_DIR/simulator-derived-data" \
  -resultBundlePath "$TEST_RESULTS" \
  -parallel-testing-enabled NO \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$ARTIFACTS/simulator-tests.log"
xcrun xcresulttool export attachments --path "$TEST_RESULTS" \
  --output-path "$ARTIFACTS/screenshots" \
  2>&1 | tee "$ARTIFACTS/attachment-export.log"

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
test -d "$APP/Resources/Reborn"
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
    resource_prefix = prefix + "Resources/Reborn/"
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

cat > "$ARTIFACTS/README.txt" <<'TXT'
CC98RebornShell-unsigned-device.ipa is a device candidate, NOT an install-ready signed app.
It contains Payload/CC98RebornShell.app built for iPhoneOS arm64, minimum iOS 17.0.
Self-sign it locally with your chosen signing tool before installing on your iPhone.
No Apple account, provisioning profile, forum session or credentials were used by this build.
simulator-tests.xcresult and screenshots contain synthetic/offline test evidence only.
Passing cloud tests does not establish school/VPN connectivity, real login or physical-device acceptance.
TXT
# Expose the IPA only after tests, device build and ZIP/platform checks all pass.
mv "$RUN_DIR/candidate.zip" "$ARTIFACTS/CC98RebornShell-unsigned-device.ipa"
echo "Unsigned device candidate: $ARTIFACTS/CC98RebornShell-unsigned-device.ipa"
