"""Static validation for the TapSound project.

Checks the generated Xcode project, scheme, asset catalog, and the invariants
the custom sound library relies on. Uses only the Python standard library so it
can run before xcodebuild on a CI runner.
"""

from __future__ import annotations

import json
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = ROOT / "TapSound.xcodeproj"
PBXPROJ = PROJECT_DIR / "project.pbxproj"
APP_DIR = ROOT / "TapSound"

OID_RE = re.compile(r"^[0-9A-F]{24}$")
errors: list[str] = []
checks = 0


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        errors.append(message)


class OpenStepParser:
    """Minimal parser for the OpenStep property-list dialect used by pbxproj."""

    def __init__(self, text: str) -> None:
        self.tokens = self.tokenize(text)
        self.index = 0
        self.duplicates: list[str] = []

    @staticmethod
    def tokenize(text: str) -> list[str]:
        tokens: list[str] = []
        index = 0
        length = len(text)
        punctuation = set("{}()=;,")

        while index < length:
            character = text[index]

            if character.isspace():
                index += 1
                continue

            if text.startswith("/*", index):
                end = text.find("*/", index + 2)
                if end < 0:
                    raise ValueError("Unterminated block comment")
                index = end + 2
                continue

            if text.startswith("//", index):
                end = text.find("\n", index + 2)
                index = length if end < 0 else end + 1
                continue

            if character in punctuation:
                tokens.append(character)
                index += 1
                continue

            if character == '"':
                index += 1
                value: list[str] = []
                while index < length:
                    character = text[index]
                    if character == '"':
                        index += 1
                        break
                    if character == "\\":
                        index += 1
                        if index >= length:
                            raise ValueError("Trailing escape in quoted string")
                        escaped = text[index]
                        value.append({"n": "\n", "t": "\t", "r": "\r"}.get(escaped, escaped))
                        index += 1
                    else:
                        value.append(character)
                        index += 1
                else:
                    raise ValueError("Unterminated quoted string")
                tokens.append("".join(value))
                continue

            start = index
            while index < length:
                character = text[index]
                if character.isspace() or character in punctuation:
                    break
                if text.startswith("/*", index) or text.startswith("//", index):
                    break
                index += 1
            tokens.append(text[start:index])

        return tokens

    def peek(self) -> str | None:
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def take(self) -> str:
        if self.index >= len(self.tokens):
            raise ValueError("Unexpected end of input")
        token = self.tokens[self.index]
        self.index += 1
        return token

    def expect(self, expected: str) -> None:
        token = self.take()
        if token != expected:
            raise ValueError(f"Expected {expected!r}, got {token!r}")

    def parse(self) -> object:
        value = self.parse_value()
        if self.peek() is not None:
            raise ValueError(f"Trailing token: {self.peek()!r}")
        return value

    def parse_value(self) -> object:
        token = self.peek()
        if token == "{":
            return self.parse_dictionary()
        if token == "(":
            return self.parse_array()
        token = self.take()
        if token in {"}", ")", "=", ";", ","}:
            raise ValueError(f"Unexpected token: {token!r}")
        return token

    def parse_dictionary(self) -> dict[str, object]:
        self.expect("{")
        result: dict[str, object] = {}
        while self.peek() != "}":
            key = self.take()
            if key in {"{", "(", "=", ";", ",", "}"}:
                raise ValueError(f"Invalid dictionary key: {key!r}")
            self.expect("=")
            value = self.parse_value()
            self.expect(";")
            if key in result:
                self.duplicates.append(key)
            result[key] = value
        self.expect("}")
        return result

    def parse_array(self) -> list[object]:
        self.expect("(")
        result: list[object] = []
        while self.peek() != ")":
            result.append(self.parse_value())
            if self.peek() == ",":
                self.take()
        self.expect(")")
        return result


def read_project() -> dict[str, object]:
    parser = OpenStepParser(PBXPROJ.read_text(encoding="utf-8"))
    root = parser.parse()
    check(not parser.duplicates, f"Duplicate pbxproj keys: {parser.duplicates[:5]}")
    check(isinstance(root, dict), "pbxproj root must be a dictionary")
    return root  # type: ignore[return-value]


def walk_all_strings(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk_all_strings(key)
            yield from walk_all_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_all_strings(child)
    elif isinstance(value, str):
        yield value


def validate_project(root: dict[str, object]) -> dict[str, object]:
    objects = root.get("objects")
    check(isinstance(objects, dict), "pbxproj has no objects dictionary")
    if not isinstance(objects, dict):
        return {}
    check(OID_RE.match(str(root.get("rootObject", ""))) is not None, "Invalid rootObject ID")
    project = objects.get(str(root.get("rootObject")))
    check(isinstance(project, dict), "rootObject does not resolve")

    for oid, object_value in objects.items():
        check(OID_RE.match(oid) is not None, f"Invalid object ID: {oid}")
        check(isinstance(object_value, dict), f"Object {oid} is not a dictionary")
    for string in walk_all_strings(root):
        if OID_RE.match(string):
            check(string in objects, f"Reference to missing object: {string}")

    if not isinstance(project, dict):
        return objects
    check(project.get("isa") == "PBXProject", "rootObject is not a PBXProject")
    targets = project.get("targets", [])
    check(isinstance(targets, list) and len(targets) == 1, "Expected exactly one target")
    target_id = targets[0] if isinstance(targets, list) and targets else None
    target = objects.get(str(target_id), {})
    check(isinstance(target, dict), "Target does not resolve")
    if not isinstance(target, dict):
        return objects

    check(target.get("isa") == "PBXNativeTarget", "Target is not a native target")
    check(target.get("productType") == "com.apple.product-type.application", "Target is not an app")

    build_phases = target.get("buildPhases", [])
    phase_objects = [objects.get(str(phase), {}) for phase in build_phases]
    source_phase = next((phase for phase in phase_objects if phase.get("isa") == "PBXSourcesBuildPhase"), None)
    resource_phase = next((phase for phase in phase_objects if phase.get("isa") == "PBXResourcesBuildPhase"), None)
    framework_phase = next((phase for phase in phase_objects if phase.get("isa") == "PBXFrameworksBuildPhase"), None)
    check(source_phase is not None, "Missing Sources build phase")
    check(resource_phase is not None, "Missing Resources build phase")
    check(framework_phase is not None, "Missing Frameworks build phase")

    file_refs = {
        oid: value
        for oid, value in objects.items()
        if isinstance(value, dict) and value.get("isa") == "PBXFileReference"
    }
    build_files = {
        oid: value
        for oid, value in objects.items()
        if isinstance(value, dict) and value.get("isa") == "PBXBuildFile"
    }
    for oid, build_file in build_files.items():
        check(str(build_file.get("fileRef")) in file_refs, f"Build file {oid} has bad fileRef")

    def filenames_for_phase(phase: dict[str, object] | None) -> set[str]:
        names: set[str] = set()
        if not phase:
            return names
        for build_id in phase.get("files", []):
            build_file = build_files.get(str(build_id), {})
            file_ref = file_refs.get(str(build_file.get("fileRef")), {})
            path = file_ref.get("path")
            if isinstance(path, str):
                names.add(Path(path).name)
        return names

    source_names = filenames_for_phase(source_phase)
    resource_names = filenames_for_phase(resource_phase)
    expected_sources = {path.name for path in APP_DIR.glob("*.swift")}
    check(source_names == expected_sources, f"Source phase mismatch: {sorted(source_names ^ expected_sources)}")
    check(resource_names == {"Assets.xcassets"}, f"Unexpected resources: {sorted(resource_names)}")

    # Resolve group paths to verify every on-disk reference exists.
    groups = {
        oid: value
        for oid, value in objects.items()
        if isinstance(value, dict) and value.get("isa") == "PBXGroup"
    }
    resolved: dict[str, Path] = {}
    seen_groups: set[str] = set()

    def visit_group(group_id: str, parent: Path) -> None:
        if group_id in seen_groups:
            return
        seen_groups.add(group_id)
        group = groups.get(group_id)
        if not isinstance(group, dict):
            return
        group_path = group.get("path")
        current = parent / group_path if isinstance(group_path, str) else parent
        for child_id in group.get("children", []):
            child = objects.get(str(child_id), {})
            if not isinstance(child, dict):
                continue
            if child.get("isa") == "PBXGroup":
                visit_group(str(child_id), current)
            elif child.get("isa") == "PBXFileReference":
                path = child.get("path")
                source_tree = child.get("sourceTree")
                if isinstance(path, str) and source_tree == "<group>":
                    resolved[str(child_id)] = current / path

    if isinstance(project.get("mainGroup"), str):
        visit_group(project["mainGroup"], ROOT)

    for oid, path in resolved.items():
        check(path.exists(), f"Missing file referenced by pbxproj: {path.relative_to(ROOT)}")

    for name in expected_sources:
        check(name in source_names, f"Swift file not compiled: {name}")

    # Build settings that matter for a runnable SwiftUI app.
    config_lists = {
        oid: value
        for oid, value in objects.items()
        if isinstance(value, dict) and value.get("isa") == "XCConfigurationList"
    }
    target_config_list = config_lists.get(str(target.get("buildConfigurationList")), {})
    target_configs = [
        objects.get(str(config_id), {})
        for config_id in target_config_list.get("buildConfigurations", [])
    ]
    check(len(target_configs) == 2, "Expected Debug and Release target configurations")
    for config in target_configs:
        settings = config.get("buildSettings", {}) if isinstance(config, dict) else {}
        check(settings.get("PRODUCT_BUNDLE_IDENTIFIER"), "Missing bundle identifier")
        check(settings.get("GENERATE_INFOPLIST_FILE") == "YES", "Generated Info.plist is disabled")
        check(settings.get("ASSETCATALOG_COMPILER_APPICON_NAME") == "AppIcon", "Missing AppIcon setting")
        check(settings.get("SWIFT_VERSION") == "5.0", "Unexpected Swift version")
        check(str(settings.get("IPHONEOS_DEPLOYMENT_TARGET", "")).startswith("17."), "Deployment target is not iOS 17")
        check(settings.get("PRODUCT_NAME") == "$(TARGET_NAME)", "Unexpected product name")

    # Scheme.
    scheme_path = PROJECT_DIR / "xcshareddata" / "xcschemes" / "TapSound.xcscheme"
    check(scheme_path.exists(), "Shared scheme is missing")
    if scheme_path.exists():
        scheme = ET.parse(scheme_path).getroot()
        references = scheme.findall(".//BuildableReference")
        check(bool(references), "Scheme has no BuildableReference")
        for reference in references:
            check(reference.get("BlueprintIdentifier") == str(target_id), "Scheme points at the wrong target")
            check(reference.get("BuildableName") == "TapSound.app", "Scheme product name mismatch")

    workspace_path = PROJECT_DIR / "project.xcworkspace" / "contents.xcworkspacedata"
    check(workspace_path.exists(), "Workspace data is missing")
    if workspace_path.exists():
        ET.parse(workspace_path)

    return objects


def validate_assets() -> None:
    icon_dir = APP_DIR / "Assets.xcassets" / "AppIcon.appiconset"
    icon_json = json.loads((icon_dir / "Contents.json").read_text(encoding="utf-8"))
    filenames = [image.get("filename") for image in icon_json.get("images", [])]
    check("AppIcon-1024.png" in filenames, "AppIcon-1024.png is not registered")

    icon_path = icon_dir / "AppIcon-1024.png"
    check(icon_path.exists(), "App icon file is missing")
    if icon_path.exists():
        data = icon_path.read_bytes()
        check(data.startswith(b"\x89PNG\r\n\x1a\n"), "App icon is not a PNG")
        check(len(data) >= 26, "App icon PNG header is too short")
        if len(data) >= 26:
            width, height = struct.unpack(">II", data[16:24])
            color_type = data[25]
            check((width, height) == (1024, 1024), f"App icon is {width}×{height}, expected 1024×1024")
            check(color_type == 2, f"App icon color type is {color_type}, expected RGB without alpha")

    for json_path in APP_DIR.glob("Assets.xcassets/**/*.json"):
        json.loads(json_path.read_text(encoding="utf-8"))

    source_text = "\n".join(path.read_text(encoding="utf-8") for path in APP_DIR.glob("*.swift"))
    required_markers = [
        "SoundBoardStore",
        "SoundItem",
        "AVAudioPlayer",
        "AVAudioSession",
        "URLSession",
        "fileImporter",
        "importRemoteSound",
        "importFiles",
        "library.json",
        "UniformTypeIdentifiers"
    ]
    for marker in required_markers:
        check(marker in source_text, f"Missing custom import marker: {marker}")

    check("SoundEffect" not in source_text, "Old fixed sound catalog is still present")
    check(not list(APP_DIR.rglob("*.wav")), "Old bundled WAV files are still present")


def swift_balance_errors(source: str) -> list[str]:
    """A light-weight bracket balance check that understands Swift strings/comments."""
    errors: list[str] = []
    stack: list[tuple[str, int]] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    index = 0
    line = 1
    length = len(source)
    block_depth = 0
    in_line_comment = False
    in_string = False
    multiline_string = False

    while index < length:
        character = source[index]
        if character == "\n":
            line += 1
            in_line_comment = False
            index += 1
            continue

        if in_line_comment:
            index += 1
            continue

        if block_depth:
            if source.startswith("/*", index):
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                block_depth -= 1
                index += 2
            else:
                index += 1
            continue

        if in_string:
            if multiline_string:
                if source.startswith('"""', index):
                    in_string = False
                    multiline_string = False
                    index += 3
                elif character == "\\":
                    index += 2
                else:
                    index += 1
            else:
                if character == "\\":
                    index += 2
                elif character == '"':
                    in_string = False
                    index += 1
                else:
                    index += 1
            continue

        if source.startswith("//", index):
            in_line_comment = True
            index += 2
        elif source.startswith("/*", index):
            block_depth = 1
            index += 2
        elif source.startswith('"""', index):
            in_string = True
            multiline_string = True
            index += 3
        elif character == '"':
            in_string = True
            index += 1
        elif character in "([{":
            stack.append((character, line))
            index += 1
        elif character in ")]}":
            if not stack or stack[-1][0] != pairs[character]:
                errors.append(f"unexpected {character!r} on line {line}")
            else:
                stack.pop()
            index += 1
        else:
            index += 1

    if in_string:
        errors.append(f"unterminated string (started near line {line})")
    if block_depth:
        errors.append("unterminated block comment")
    for character, start_line in stack:
        errors.append(f"unclosed {character!r} from line {start_line}")
    return errors


def validate_swift() -> None:
    files = sorted(APP_DIR.glob("*.swift"))
    check(bool(files), "No Swift files found")

    for path in files:
        source = path.read_text(encoding="utf-8")
        for balance_error in swift_balance_errors(source):
            check(False, f"{path.name}: {balance_error}")

    source_text = "\n".join(path.read_text(encoding="utf-8") for path in files)
    for required in [
        "@main",
        "SoundBoardStore",
        "SoundBoardView",
        "AVAudioPlayer",
        "AVAudioSession",
        ".safeAreaInset",
        "accessibilityReduceMotion",
        "isAccessibilitySize",
        ".fileImporter",
        "URLSession",
    ]:
        check(required in source_text, f"Missing expected code marker: {required}")

    for forbidden in ["SoundEffect.all", "resourceName"]:
        check(forbidden not in source_text, f"Old built-in audio path is still referenced: {forbidden}")


def main() -> int:
    root = read_project()
    objects = validate_project(root)
    check(bool(objects), "Project objects could not be loaded")
    validate_assets()
    validate_swift()

    if errors:
        print(f"FAIL — {len(errors)} issue(s) across {checks} checks")
        for error in errors:
            print(f"  - {error}")
        return 1

    print(f"OK - {checks} checks passed")
    print(f"  project: {PBXPROJ.relative_to(ROOT)}")
    print(f"  swift:   {len(list(APP_DIR.glob('*.swift')))} source files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
