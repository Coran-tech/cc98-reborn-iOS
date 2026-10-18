// Portable contract tests; these do not pretend to compile Swift on Windows.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
const script = read('scripts/build-ios-shell.sh');
const github = read('.github/workflows/ios-shell.yml');
const codemagic = read('codemagic.yaml');
function pythonCommand() {
  const command = ['python3', 'python'].find((name) => {
    const result = spawnSync(name, ['--version'], { encoding: 'utf8' });
    return !result.error && result.status === 0 && /Python 3\./.test(result.stdout + result.stderr);
  });
  assert(command, 'Python 3 is required to exercise the production build helpers');
  return command;
}

test('both providers share one build entry point and stable Xcode', () => {
  for (const workflow of [github, codemagic]) {
    assert.match(workflow, /bash scripts\/build-ios-shell\.sh/);
    assert.doesNotMatch(workflow, /xcodebuild\s+(?:test|build|archive)|(?:latest|beta|edge)\s*$/m);
    assert.doesNotMatch(workflow, /(?:app_store_connect|testflight|publishing|ios_signing):/i);
  }
  assert.match(github, /runs-on: macos-15\s/);
  assert.match(github, /DEVELOPER_DIR: \/Applications\/Xcode_26\.0\.1\.app\/Contents\/Developer/);
  assert.match(codemagic, /instance_type: mac_mini_m2/);
  assert.match(codemagic, /xcode: 26\.0\.1/);
  assert.match(script, /grep -Fxq 'Xcode 26\.0\.1'/);
  assert.match(script, /node --test tests\/ios-\*\.test\.cjs/);
  assert.match(script, /releases\/download\/2\.46\.0\/xcodegen\.zip/);
  assert.match(script, /XCODEGEN="\$RUN_DIR\/tools\/xcodegen\/bin\/xcodegen"/);
  assert.doesNotMatch(script, /brew install xcodegen/);
});

test('triggers are manual or restricted to the dedicated bootstrap branch', () => {
  assert.match(github, /\n  workflow_dispatch:\s*\n/);
  assert.match(github, /\n  push:\s*\n    branches: \[codex\/ios-verification-shell\]\s*\n    paths:/);
  assert.doesNotMatch(github, /\n  (?:pull_request|pull_request_target|schedule|workflow_run):/);
  assert.doesNotMatch(codemagic, /^\s*(?:triggering|events|branch_patterns):/m);
  assert.match(github, /contents: read/);
  assert.match(github, /persist-credentials: false/);
  assert.match(github, /- images\/\*\*/);
  assert.match(github, /- assets\/\*\*/);
});

test('resources are packaged before generating the exact Xcode project', () => {
  const packageIndex = script.indexOf('\nnode scripts/package-ios-resources.cjs');
  const generateIndex = script.indexOf('\n"$XCODEGEN" generate --spec ios/project.yml --project ios');
  assert(packageIndex > 0 && packageIndex < generateIndex);
  assert.match(script, /PROJECT="\$ROOT\/ios\/CC98RebornShell\.xcodeproj"/);
  assert.match(script, /SCHEME=CC98RebornShell/);
  assert.match(script, /test -d "\$APP\/Reborn"/);
  assert.match(script, /test ! -e "\$APP\/Resources"/);
});

test('simulator tests run before the separate arm64 iPhoneOS device build', () => {
  const testIndex = script.indexOf('\nrun_with_timeout 600 xcodebuild test \\\n');
  const buildIndex = script.indexOf('\nxcodebuild build \\\n');
  assert(testIndex > 0 && buildIndex > testIndex);
  const tests = script.slice(testIndex, buildIndex);
  const device = script.slice(buildIndex, script.indexOf('# BEGIN IPA_VALIDATOR'));
  assert.match(tests, /-sdk iphonesimulator/);
  assert.match(script, /SIMULATOR_DESTINATION="\$\{SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 16,OS=26\.0\.1\}"/);
  assert.match(script, /printf '%s\\n' "\$SIMULATOR_DESTINATION" \| tee "\$ARTIFACTS\/simulator-destination\.txt"/);
  assert.match(tests, /-destination "platform=iOS Simulator,id=\$SIMULATOR_UDID"/);
  assert.match(script, /run_with_timeout 60 xcrun simctl boot "\$SIMULATOR_UDID"/);
  assert.match(script, /run_with_timeout 180 xcrun simctl bootstatus "\$SIMULATOR_UDID" -b/);
  assert(script.indexOf('simctl bootstatus') < testIndex);
  assert.match(tests, /-test-timeouts-enabled YES/);
  assert.match(tests, /-default-test-execution-time-allowance 60/);
  assert.match(tests, /-maximum-test-execution-time-allowance 120/);
  assert.match(tests, /simulator-derived-data/);
  assert.match(tests, /-resultBundlePath "\$TEST_RESULTS"/);
  assert.match(tests, /xcresulttool export attachments/);
  assert.doesNotMatch(tests, /only-testing/); // Includes unit and UI tests in the shared scheme.
  assert.match(device, /-sdk iphoneos -destination 'generic\/platform=iOS'/);
  assert.match(device, /ARCHS=arm64 ONLY_ACTIVE_ARCH=NO/);
  assert.match(script, /BUILD_NUMBER="\$\{GITHUB_RUN_NUMBER:-\$\{BUILD_NUMBER:-1\}\}"/);
  assert.match(device, /CURRENT_PROJECT_VERSION="\$BUILD_NUMBER"/);
  assert.match(device, /CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=/);
  assert.match(device, /device-derived-data\/Build\/Products\/Release-iphoneos\/CC98RebornShell\.app/);
  assert.doesNotMatch(device, /Release-iphonesimulator|allowProvisioningUpdates|exportArchive/);
});

test('only a successful validated Payload becomes a candidate artifact', () => {
  assert.match(script, /set -euo pipefail/);
  assert.match(script, /mktemp -d "\$ROOT\/build\/ios-shell\/run\.XXXXXX"/);
  assert.match(script, /ditto "\$APP" "\$RUN_DIR\/staging\/Payload\/CC98RebornShell\.app"/);
  assert.match(script, /ditto -c -k --norsrc --keepParent "\$RUN_DIR\/staging\/Payload" "\$RUN_DIR\/candidate\.zip"/);
  assert.match(script, /mv "\$RUN_DIR\/candidate\.zip" "\$ARTIFACTS\/CC98RebornShell-unsigned-device\.ipa"/);
  assert(script.indexOf('# END IPA_VALIDATOR') < script.indexOf('\nmv '));
  assert.equal((script.match(/\|\| true/g) || []).length, 1, 'Only failed-test attachment recovery may be best effort');
  assert.doesNotMatch(script, /security\s+import|notarytool|altool|app-store-connect|git\s+(?:push|commit)/);
  assert.doesNotMatch(script, /\b(?:killall|pkill)\b|simctl\s+(?:erase|shutdown)\s+all/);
});

test('failures retain diagnostics without uploading the checkout', () => {
  assert.match(github, /if: always\(\)/);
  assert.match(github, /path: build\/ios-shell\/run\.\*\/artifacts\//);
  assert.match(github, /retention-days: 14/);
  assert.match(codemagic, /- build\/ios-shell\/run\.\*\/artifacts\/\*\*/);
  assert.match(script, /trap finish EXIT/);
  assert.match(script, /simulator-tests\.xcresult/);
  assert.match(script, /device-build\.xcresult/);
  assert.match(script, /build-status\.txt/);
  assert.match(script, /local simulator_plist="\$RUN_DIR\/simulator-derived-data\/Build\/Products\/Debug-iphonesimulator\/CC98RebornShell\.app\/Info\.plist"/);
  assert.match(script, /if \[\[ -f "\$simulator_plist" \]\]; then/);
  assert.match(script, /cp "\$simulator_plist" "\$ARTIFACTS\/simulator-app-Info\.plist"/);
  assert.match(script, /source-plist-identity\.json/);
  assert.match(script, /generated-build-identity\.json/);
  assert(script.indexOf('generated-build-identity.json') < script.indexOf('\nrun_with_timeout 600 xcodebuild test '));
  for (const artifact of ['selected-simulator.json', 'simulator-boot.log', 'simulator-bootstatus.log', 'simulator-devices-after-boot.json', 'simulator-state-on-exit.json']) assert(script.includes(artifact));
});

test('exact available Simulator selection does not fall back to another OS or device', () => {
  const match = script.match(/# BEGIN SIMULATOR_SELECTOR\npython3[^\n]*\n([\s\S]*?)\nPY\n# END SIMULATOR_SELECTOR/);
  assert(match);
  const harness = String.raw`
import contextlib, io, json, os, sys, tempfile
source = sys.stdin.read()
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
selected = "11111111-1111-4111-8111-111111111111"
with tempfile.TemporaryDirectory(prefix="cc98-simulator-contract-") as folder:
    runtime_file, device_file = os.path.join(folder,"runtimes.json"), os.path.join(folder,"devices.json")
    json.dump({"runtimes":[{"identifier":runtime,"version":"26.0.1","isAvailable":True}]},open(runtime_file,"w"))
    valid = {"name":"iPhone 16","udid":selected,"state":"Shutdown","isAvailable":True}
    for mode in ("exact", "wrong-os", "wrong-name", "unavailable", "duplicate"):
        devices = [dict(valid)]
        if mode == "unavailable": devices[0]["isAvailable"] = False
        if mode == "duplicate": devices.append(dict(valid,udid="22222222-2222-4222-8222-222222222222"))
        json.dump({"devices":{runtime:devices}},open(device_file,"w"))
        destination = "platform=iOS Simulator,name=%s,OS=%s" % ("iPhone 17" if mode == "wrong-name" else "iPhone 16", "26.0" if mode == "wrong-os" else "26.0.1")
        sys.argv = ["selector",destination,runtime_file,device_file]
        output = io.StringIO()
        succeeded = True
        try:
            with contextlib.redirect_stdout(output): exec(source,{"__name__":"__main__"})
        except AssertionError:
            succeeded = False
        assert succeeded == (mode == "exact"), mode
        if succeeded: assert json.loads(output.getvalue())["udid"] == selected
print("5 Simulator selection cases passed")
`;
  const result = spawnSync(pythonCommand(), ['-c', harness], { input: match[1], encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /5 Simulator selection cases passed/);
});

test('watchdog preserves exits and terminates only its owned group on timeout', () => {
  const match = script.match(/run_with_timeout\(\) \{\n[^\n]*\n  python3[^\n]*\n([\s\S]*?)\nPY\n\}/);
  assert(match);
  const harness = String.raw`
import contextlib, io, signal, subprocess, sys
from unittest.mock import patch, Mock
source = sys.stdin.read()
for mode in ("success", "failure", "timeout"):
    process = Mock(pid=12345)
    process.wait.side_effect = [0] if mode == "success" else [7] if mode == "failure" else [subprocess.TimeoutExpired("owned-command",1), -15, -15]
    sys.argv = ["watchdog","1","owned-command"]
    with patch("subprocess.Popen",return_value=process) as start, patch("os.killpg",create=True) as kill, patch.object(signal,"SIGKILL",9,create=True):
        try:
            with contextlib.redirect_stdout(io.StringIO()): exec(source,{"__name__":"__main__"})
        except SystemExit as exit:
            assert exit.code == {"success":0,"failure":7,"timeout":124}[mode]
        else: raise AssertionError("Watchdog did not propagate exit")
        start.assert_called_once_with(["owned-command"], start_new_session=True)
        if mode == "timeout":
            assert [call.args for call in kill.call_args_list] == [(12345,signal.SIGTERM),(12345,signal.SIGKILL)]
        else: kill.assert_not_called()
print("3 watchdog cases passed")
`;
  const result = spawnSync(pythonCommand(), ['-c', harness], { input: match[1], encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /3 watchdog cases passed/);
});

test('actual IPA validator rejects simulator, malformed ZIPs, and signed or empty candidates', () => {
  const match = script.match(/# BEGIN IPA_VALIDATOR[^\n]*\npython3[^\n]*\n([\s\S]*?)\nPY\n# END IPA_VALIDATOR/);
  assert(match, 'The validator must stay directly testable');
  const python = pythonCommand();
  const harness = String.raw`
import contextlib, io, json, os, plistlib, stat, struct, sys, tempfile, zipfile
request = json.load(sys.stdin)
prefix = "Payload/CC98RebornShell.app/"
results = []
with tempfile.TemporaryDirectory(prefix="cc98-ipa-contract-") as folder:
    for case in request["cases"]:
        info = {"CFBundleIdentifier": "org.cc98.reborn.shell", "CFBundleExecutable": "CC98RebornShell", "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "iphoneos", "MinimumOSVersion": "17.0"}
        info.update(case.get("info", {}))
        binary = struct.pack("<8I", 0xFEEDFACF, case.get("cpu", 0x0100000C), 0, 2, 1, 24, 0, 0) + struct.pack("<6I", 0x32, 24, case.get("platform", 2), 0x110000, 0x1A0000, 0)
        members = [(prefix + "Info.plist", plistlib.dumps(info), 0o100644), (prefix + "CC98RebornShell", binary, case.get("mode", 0o100755))]
        if not case.get("emptyResources"):
            index = {"schemaVersion": 1, "extensionVersion": "0.4.1", "pageScripts": ["src/page-submit-monitor.js"], "contentScripts": ["runtime/ios-adapter.js", "src/topic-drawer.js", "src/content.js"], "styles": ["runtime/ios-mobile.css"], "assets": ["popup/popup.html", "src/content-filter-frame.html", "src/content-filter-frame.js", "src/content-filter-worker.js", "src/content-filter-core.js"]}
            if case.get("unsafeIndex"):
                index["assets"].append("../outside.txt")
            if case.get("background"):
                index["assets"].append("src/background.js")
            resource_prefix = prefix + ("Resources/Reborn/" if case.get("legacyLayout") else "Reborn/")
            members.append((resource_prefix + "manifest-index.json", json.dumps(index).encode(), 0o100644))
            for group in ("pageScripts", "contentScripts", "styles", "assets"):
                for resource in index[group]:
                    if resource != case.get("missingResource"):
                        members.append((resource_prefix + resource, b"synthetic", 0o100644))
        for name in case.get("extra", []):
            members.append((name, b"synthetic", 0o100644))
        if case.get("duplicate"):
            members.append(members[-1])
        if case.get("symlink"):
            members.append((prefix + "link", b"../../../outside", stat.S_IFLNK | 0o777))
        location = os.path.join(folder, "candidate.zip")
        with zipfile.ZipFile(location, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data, mode in members:
                entry = zipfile.ZipInfo(name)
                entry.filename = name  # Keep unsafe backslashes even on Windows.
                entry.create_system = 3
                entry.external_attr = mode << 16
                archive.writestr(entry, data)
        sys.argv = ["ipa-validator", location]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                exec(request["validator"], {"__name__": "__main__"})
            results.append({"name": case["name"], "passed": True})
        except Exception as error:
            results.append({"name": case["name"], "passed": False, "error": str(error)})
print(json.dumps(results))
`;
  const prefix = 'Payload/CC98RebornShell.app/';
  const cases = [
    { name: 'device', expected: true },
    { name: 'simulator-plist', info: { CFBundleSupportedPlatforms: ['iPhoneSimulator'], DTPlatformName: 'iphonesimulator' } },
    { name: 'arm64-simulator-binary', platform: 7 },
    { name: 'x86-binary', cpu: 0x01000007 },
    { name: 'wrong-bundle', info: { CFBundleIdentifier: 'invalid.bundle' } },
    { name: 'wrong-minimum', info: { MinimumOSVersion: '26.0' } },
    { name: 'non-executable', mode: 0o100644 },
    { name: 'missing-resources', emptyResources: true },
    { name: 'missing-indexed-resource', missingResource: 'src/content.js' },
    { name: 'unsafe-index', unsafeIndex: true },
    { name: 'extension-background', background: true },
    { name: 'unindexed-resource', extra: [prefix + 'Reborn/private.txt'] },
    { name: 'legacy-resources-layout', legacyLayout: true },
    { name: 'forbidden-top-level-resources', extra: [prefix + 'Resources/unexpected.txt'] },
    { name: 'outside-payload', extra: ['source/secret.txt'] },
    { name: 'traversal', extra: [prefix + '../../outside.txt'] },
    { name: 'absolute', extra: ['/Payload/CC98RebornShell.app/outside'] },
    { name: 'windows-path', extra: [prefix + 'folder\\outside'] },
    { name: 'signature', extra: [prefix + '_CodeSignature/CodeResources'] },
    { name: 'profile', extra: [prefix + 'embedded.mobileprovision'] },
    { name: 'duplicate', duplicate: true },
    { name: 'symlink', symlink: true },
  ];
  const run = spawnSync(python, ['-c', harness], {
    input: JSON.stringify({ validator: match[1], cases }), encoding: 'utf8', maxBuffer: 1024 * 1024,
  });
  assert.equal(run.status, 0, run.stderr);
  const results = JSON.parse(run.stdout);
  assert.equal(results.length, cases.length);
  for (let i = 0; i < cases.length; i += 1) {
    assert.equal(results[i].name, cases[i].name);
    assert.equal(results[i].passed, !!cases[i].expected, JSON.stringify(results[i]));
  }
});
