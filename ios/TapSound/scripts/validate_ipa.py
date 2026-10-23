"""Validate the unsigned TapSound IPA produced by GitHub Actions."""

from __future__ import annotations

import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

EXPECTED_BUNDLE_ID = "com.example.tapsound"
EXECUTABLE = "TapSound"
APP_PREFIX = "Payload/TapSound.app/"
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: validate_ipa.py <path-to-ipa>")

    ipa_path = Path(sys.argv[1])
    if not ipa_path.is_file():
        fail(f"missing IPA: {ipa_path}")

    with zipfile.ZipFile(ipa_path) as archive:
        bad_member = archive.testzip()
        if bad_member:
            fail(f"corrupt ZIP member: {bad_member}")

        names = archive.namelist()
        if not names:
            fail("empty IPA")

        for name in names:
            if name.startswith("/") or "\\" in name or ".." in Path(name).parts:
                fail(f"unsafe ZIP path: {name}")
            if name != "Payload/" and not name.startswith(APP_PREFIX):
                fail(f"unexpected ZIP member: {name}")
            if name.startswith(APP_PREFIX + "_CodeSignature/"):
                fail("unsigned IPA unexpectedly contains _CodeSignature")
            if name == APP_PREFIX + "embedded.mobileprovision":
                fail("unsigned IPA unexpectedly contains a provisioning profile")
            if name.startswith(APP_PREFIX + "Resources/"):
                fail("app contains a disallowed top-level Resources directory")

        info_plist_path = APP_PREFIX + "Info.plist"
        executable_path = APP_PREFIX + EXECUTABLE
        assets_path = APP_PREFIX + "Assets.car"
        for required in (info_plist_path, executable_path, assets_path):
            if required not in names:
                fail(f"missing {required}")

        info = plistlib.loads(archive.read(info_plist_path))
        if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
            fail(f"unexpected bundle id: {info.get('CFBundleIdentifier')!r}")
        if info.get("CFBundleExecutable") != EXECUTABLE:
            fail(f"unexpected executable: {info.get('CFBundleExecutable')!r}")
        if info.get("CFBundlePackageType") != "APPL":
            fail(f"unexpected package type: {info.get('CFBundlePackageType')!r}")
        minimum_os = str(info.get("MinimumOSVersion", ""))
        if not minimum_os.startswith("17."):
            fail(f"MinimumOSVersion is {minimum_os!r}, expected 17.x")

        binary = archive.read(executable_path)
        if len(binary) < 32:
            fail("Mach-O executable is too short")
        magic, cpu_type, _cpu_subtype, file_type, command_count, _command_size, _flags, _reserved = struct.unpack_from(
            "<IiiIIIII", binary, 0
        )
        if magic != 0xFEEDFACF:
            fail(f"not a thin 64-bit little-endian Mach-O: magic={magic:#x}")
        if cpu_type != 0x0100000C:
            fail(f"expected arm64 device slice, cpu_type={cpu_type:#x}")
        if file_type != 2:
            fail(f"expected MH_EXECUTE, file_type={file_type}")

        offset = 32
        found_ios_platform = False
        for _ in range(command_count):
            if offset + 8 > len(binary):
                fail("truncated Mach-O load commands")
            command, command_size = struct.unpack_from("<II", binary, offset)
            if command_size < 8 or offset + command_size > len(binary):
                fail("invalid Mach-O load command size")
            if command == LC_BUILD_VERSION and command_size >= 12:
                platform = struct.unpack_from("<I", binary, offset + 8)[0]
                if platform == PLATFORM_IOS:
                    found_ios_platform = True
            offset += command_size
        if not found_ios_platform:
            fail("Mach-O does not declare the iOS platform")

        binary_count = sum(1 for name in names if name.startswith(APP_PREFIX + "TapSound") and not name.endswith(".plist"))
        summary = {
            "ipa": str(ipa_path),
            "bundleId": info.get("CFBundleIdentifier"),
            "executable": EXECUTABLE,
            "minimumOS": minimum_os,
            "architecture": "arm64",
            "unsigned": True,
            "zipMembers": len(names),
            "nativeEntries": binary_count,
        }

    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: validate_ipa.py <path-to-ipa>")
    main()
