#!/usr/bin/env python3
"""Fail-closed submission packaging using only the Python standard library.

Run with --check for an audit without writing, or --output /path/submission.zip.
Text architecture artifacts (SVG, Mermaid, drawio XML) are supported under docs.
Opaque/binary artifacts require a separate visual/format-aware review and are
rejected, including PDF, raster images and nested archives. No secret values are
printed. This heuristic audit is not a guarantee that a submission is complete.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
TREES = {"src", "test", "script", "scripts", "docs"}
ROOT_FILES = {
    "Makefile", "README", "README.md", "STUDENT-QUESTIONS.md", "EXERCISES.md",
    "FOUNDRY-101.md", "foundry.toml", "foundry.lock", "remappings.txt",
    "LICENSE", "LICENSE.md", "LICENSE-MIT", "LICENSE-APACHE", "NOTICE",
    ".gitignore", ".gitattributes", ".gitmodules",
}
LIB_TREES = {
    "forge-std": "src",
    "openzeppelin-contracts": "contracts",
}
LIB_FILES = {
    "LICENSE", "LICENSE.md", "LICENSE-MIT", "LICENSE-APACHE", "NOTICE",
    "NOTICE.md", "README.md", "package.json", "foundry.toml", "remappings.txt",
}
REQUIRED = {
    "Makefile", "README.md", "STUDENT-QUESTIONS.md", "EXERCISES.md",
    "FOUNDRY-101.md", "foundry.toml", "remappings.txt",
    "scripts/package_submission.py", "lib/forge-std/src/Test.sol",
    "lib/forge-std/LICENSE-MIT", "lib/forge-std/LICENSE-APACHE",
    "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol",
    "lib/openzeppelin-contracts/LICENSE",
}
DENIED = {
    ".git", "broadcast", "cache", "out", "node_modules", "__pycache__",
    "wallet", "wallets", "keystore", "keystores", "secrets", ".ssh",
}
TEXT_SUFFIXES = {
    ".sol", ".py", ".sh", ".md", ".txt", ".toml", ".json", ".lock",
    ".yaml", ".yml", ".svg", ".mmd", ".mermaid", ".drawio", ".xml",
    ".html", ".css", ".js", ".ts", ".rst", ".adoc", ".csv",
}
MANIFEST = "SUBMISSION-MANIFEST.json"
SECRET_NAME = (
    r"(?:[A-Za-z0-9_]*(?:private[\s_-]?key|secret[\s_-]?key|signing[\s_-]?key|"
    r"anvil[_-]?key|attack[_-]?key|mnemonic|seed[_-]?phrase|recovery[_-]?phrase)"
    r"[A-Za-z0-9_]*|pk|私钥|助记词)"
)
# Match literal values with semantic context, never arbitrary bytes32/hash data.
ASSIGNMENT = re.compile(
    rf"""(?ix)\b{SECRET_NAME}\b["']?\s*(?::=|=|:)\s*
    (?:(?:uint256|bytes32)\s*\(\s*)?
    (?P<value>"[^"\n]*"|'[^'\n]*'|(?:0x[0-9a-f]+|\d+)\b)"""
)
CLI_SECRET = re.compile(
    r"""(?ix)--(?:private-key|mnemonic|seed-phrase)(?:=|\s+)
    (?P<value>"[^"\n]*"|'[^'\n]*'|0x[0-9a-f]+\b|[0-9a-f]{64}\b|\d+\b)"""
)
PEM = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")
KEY_LITERAL = re.compile(r"(?i)^(?:0x[0-9a-f]+|[0-9a-f]{64}|\d+)$")
WORDS = re.compile(r"^[a-z]+(?:\s+[a-z]+){11,23}$", re.I)
ENCODED_IMAGE = re.compile(
    r"(?i)data:[^;\s\"']+;base64,|<image\b|<foreignObject\b|<diagram\b[^>]*>\s*[^<\s]"
)


class AuditError(Exception):
    pass


def exclusion(path):
    for part in path.parts:
        name = part.lower()
        if (name in DENIED or name.startswith((".env", "reference-"))
                or re.search(r"(?:^|[._-])(wallets?|keystores?|secrets?|private[-_]?keys?)(?:[._-]|$)", name)
                or name.endswith((".pem", ".key", ".p12", ".pfx", ".jks"))):
            return "forbidden path (environment, reference, build output or key storage)"
    return None


def allowed(path):
    parts = path.parts
    if exclusion(path):
        return False
    if len(parts) == 1:
        return parts[0] in ROOT_FILES
    if parts[0] in TREES:
        return True
    if len(parts) >= 3 and parts[0] == "lib" and parts[1] in LIB_TREES:
        return (parts[2] == LIB_TREES[parts[1]] and len(parts) > 3
                or len(parts) == 3 and parts[2] in LIB_FILES)
    return False


def secret_findings(text):
    findings = []
    for match in PEM.finditer(text):
        findings.append((text.count("\n", 0, match.start()) + 1, "PEM private key"))
    for pattern in (ASSIGNMENT, CLI_SECRET):
        for match in pattern.finditer(text):
            value = match.group("value").strip("\"'")
            if KEY_LITERAL.fullmatch(value) or WORDS.fullmatch(value):
                findings.append((text.count("\n", 0, match.start()) + 1,
                                 "literal signing key or seed phrase"))
    # Common unlabelled mnemonic: identify the public Anvil seed structurally,
    # without embedding a usable mnemonic in this script.
    common_seed = re.compile(r"\b(?:test\s+){11}junk\b")
    for match in common_seed.finditer(text):
        findings.append((text.count("\n", 0, match.start()) + 1, "public test seed phrase"))
    # Ethereum encrypted wallet JSON is still sensitive key storage.
    if re.search(r'"(?:crypto|Crypto)"\s*:', text) and re.search(r'"ciphertext"\s*:', text):
        findings.append((1, "encrypted wallet JSON"))
    return sorted(set(findings))


def scan(name, data):
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise AuditError(f"{name}: binary/non-UTF-8 content requires separate review")
    if "\x00" in text:
        raise AuditError(f"{name}: binary content requires separate review")
    suffix = PurePosixPath(name).suffix.lower()
    if suffix and suffix not in TEXT_SUFFIXES and PurePosixPath(name).name not in ROOT_FILES:
        raise AuditError(f"{name}: unsupported file format")
    findings = secret_findings(text)
    if findings:
        details = ", ".join(f"line {line}: {reason}" for line, reason in findings)
        raise AuditError(f"{name}: {details} (values redacted)")
    if suffix in {".svg", ".drawio", ".xml", ".html", ".md"} and ENCODED_IMAGE.search(text):
        raise AuditError(f"{name}: embedded image/encoded diagram requires separate review")


def collect(root):
    payload = {}
    excluded = []
    failures = []

    def walk(directory):
        for item in sorted(directory.iterdir()):
            rel = PurePosixPath(item.relative_to(root).as_posix())
            reason = exclusion(rel)
            # Only descend into explicit roots and the two reviewed dependency trees.
            traversable = (
                len(rel.parts) == 1 and rel.name in TREES | {"lib"}
                or rel.parts[0] in TREES
                or len(rel.parts) == 2 and rel.parts[0] == "lib" and rel.name in LIB_TREES
                or len(rel.parts) >= 3 and rel.parts[0] == "lib"
                and rel.parts[1] in LIB_TREES and rel.parts[2] == LIB_TREES[rel.parts[1]]
            )
            mode = item.lstat().st_mode
            if reason or not (allowed(rel) or traversable):
                excluded.append({"path": str(rel), "reason": reason or "outside reviewed whitelist"})
                continue
            if stat.S_ISLNK(mode):
                raise AuditError(f"{rel}: symlink is not permitted")
            if stat.S_ISDIR(mode):
                walk(item)
            elif stat.S_ISREG(mode) and allowed(rel):
                # O_NOFOLLOW also prevents swapping a candidate for a symlink.
                fd = os.open(item, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream:
                    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                        raise AuditError(f"{rel}: not a regular file")
                    data = stream.read()
                try:
                    scan(str(rel), data)
                except AuditError as error:
                    failures.append(str(error))
                payload[str(rel)] = data
            else:
                raise AuditError(f"{rel}: unsupported filesystem entry")

    walk(root)
    if failures:
        raise AuditError("\n" + "\n".join(failures))
    missing = REQUIRED - payload.keys()
    if missing:
        raise AuditError("Missing required files: " + ", ".join(sorted(missing)))
    for tree in ("src", "test", "script"):
        if not any(name.startswith(tree + "/") and name.endswith(".sol") for name in payload):
            raise AuditError(f"Missing Solidity sources in {tree}")
    audit_imports(payload)
    return payload, excluded


def audit_imports(payload):
    """Verify that stripping dependency tests did not remove imported sources."""
    mappings = []
    for line in payload["remappings.txt"].decode().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            prefix, target = line.strip().split("=", 1)
            mappings.append((prefix, target))
    mappings.sort(key=lambda pair: len(pair[0]), reverse=True)
    for name, data in payload.items():
        if not name.endswith(".sol"):
            continue
        text = re.sub(r"/\*.*?\*/|//[^\n]*", "", data.decode(), flags=re.S)
        for match in re.finditer(r"""\bimport\s+(?:[^;]*?\bfrom\s+)?["']([^"']+)["']\s*;""", text):
            imported = match.group(1)
            if imported.startswith("."):
                target = os.path.normpath(str(PurePosixPath(name).parent / imported))
            else:
                target = imported
                for prefix, replacement in mappings:
                    if imported.startswith(prefix):
                        target = replacement + imported[len(prefix):]
                        break
                target = os.path.normpath(target)
            if target not in payload:
                raise AuditError(f"{name}: import missing from archive: {imported}")


def manifest_for(payload, excluded):
    return {
        "format": 1,
        "scope": "Packaging audit only; not a final completeness certification",
        "dependency_policy": {
            "forge-std": "src and metadata/licenses only; test seed/key fixtures excluded",
            "openzeppelin-contracts": "contracts and metadata/licenses only; tests and nested lib excluded",
        },
        "reviewed_secret_fixtures": [
            {"path": "lib/forge-std/test/StdCheats.t.sol",
             "evidence": "lines 230/234: public test seed and private-key assertion"},
            {"path": "lib/openzeppelin-contracts/lib/forge-std/test/StdCheats.t.sol",
             "evidence": "line 156: public test seed"},
            {"path": "lib/openzeppelin-contracts/test/metatx/ERC2771Forwarder.t.sol",
             "evidence": "lines 57/58: literal signer/relayer test keys"},
        ],
        "scan_limits": "UTF-8 text; contextual key literals, PEM, labelled seed phrases; no OCR or arbitrary secret detection",
        "files": [
            {"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in sorted(payload.items())
        ],
        "excluded": excluded,
    }


def verify(archive, manifest):
    with zipfile.ZipFile(archive) as bundle:
        expected = {entry["path"]: entry for entry in manifest["files"]}
        names = bundle.namelist()
        if len(names) != len(set(names)) or set(names) != set(expected) | {MANIFEST}:
            raise AuditError("ZIP member/manifest mismatch")
        if bundle.testzip() is not None:
            raise AuditError("ZIP CRC integrity check failed")
        if json.loads(bundle.read(MANIFEST)) != manifest:
            raise AuditError("ZIP manifest content mismatch")
        scan(MANIFEST, bundle.read(MANIFEST))
        for name, entry in expected.items():
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or not allowed(path):
                raise AuditError(f"{name}: invalid archive path")
            data = bundle.read(name)
            if len(data) != entry["size"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise AuditError(f"{name}: SHA-256/size mismatch")
            scan(name, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="audit only; write nothing")
    parser.add_argument("--output", type=Path, default=ROOT / "submission.zip")
    args = parser.parse_args()
    temporary = None
    try:
        payload, excluded = collect(ROOT)
        manifest = manifest_for(payload, excluded)
        print(f"Audited {len(payload)} files; excluded {len(excluded)} entries/subtrees.")
        print("Dependency test fixtures excluded; source trees and licenses retained.")
        if args.check:
            print("Audit passed; no archive written. Not a final completeness certification.")
            return 0
        output = args.output.absolute()
        if output.suffix.lower() != ".zip":
            raise AuditError("Output must have a .zip suffix")
        if output.exists() or output.is_symlink():
            raise AuditError("Output already exists; choose a new path (no overwrite)")
        parent = output.parent.resolve(strict=True)
        try:
            relative = parent.relative_to(ROOT)
        except ValueError:
            relative = None
        if relative is not None and relative.parts:
            raise AuditError("Write ZIP at project root or outside the project")
        fd, temporary = tempfile.mkstemp(prefix=".submission-", suffix=".tmp", dir=parent)
        with os.fdopen(fd, "w+b") as stream:
            with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
                for name, data in sorted(payload.items()):
                    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.create_system = 3
                    executable = name.endswith((".sh", ".py"))
                    info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
                    bundle.writestr(info, data)
                bundle.writestr(MANIFEST, json.dumps(manifest, indent=2, ensure_ascii=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        verify(temporary, manifest)
        # Same-filesystem exclusive publication, with no overwrite race.
        os.link(temporary, parent / output.name)
        print(f"ZIP verified (CRC, manifest, SHA-256, repeat secret scan): {output}")
        print("Packaging checks passed; this is not a final completeness certification.")
        return 0
    except (AuditError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"Packaging refused: {error}", file=sys.stderr)
        return 1
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
