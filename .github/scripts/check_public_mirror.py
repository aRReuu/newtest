#!/usr/bin/env python3
"""Static public-source publishing gate. No iOS build or network calls."""
from __future__ import annotations
import json
from pathlib import Path
import re
import subprocess
import sys

FILES = [x.decode("utf-8") for x in subprocess.check_output(
    ["git", "ls-files", "-z"]).split(b"\0") if x]
IMAGE_EXTS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif",
    ".tiff", ".svg", ".ico", ".icns", ".heic", ".avif", ".apng",
    ".psd", ".eps", ".ai", ".pdf", ".sketch", ".fig",
}
PRIVATE_EXTS = {".p12",".p8",".mobileprovision",".cer",".pfx",
                ".pem",".key",".xcuserstate"}
DOC = re.compile(r"\.(?:md|mdx|rst|adoc|txt|markdown)$",re.I)
CJK = re.compile(r"[\u3400-\u9fff]")
FENCE = re.compile(r"^\s*(?:\x60{3,}|~{3,})")
INLINE = re.compile(r"\x60[^\x60\n]*\x60")
SECRET = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
    r"|gh[pousr]_[A-Za-z0-9_]{25,}"
    r"|sk-(?:proj-)?[A-Za-z0-9_-]{30,}"
    r"|AIza[A-Za-z0-9_-]{30,}"
    r"|AKIA[A-Z0-9]{16}"
    r"|xox[baprs]-[A-Za-z0-9-]{20,}"
)
errors = []
for file in FILES:
    path=Path(file);lower=file.lower()
    if path.suffix.lower() in IMAGE_EXTS or (
        ".appiconset/" in lower or ".imageset/" in lower
        or ".brandassets/" in lower or "icon_1024" in lower
    ):
        errors.append(f"{file}: prohibited image/icon path")
        continue
    if path.suffix.lower() in PRIVATE_EXTS or (
        "xcuserdata/" in lower or ".xcuserdatad/" in lower
        or "private_source_sync_" in lower
        or "retired-branch-history" in lower
        or "private_merge" in lower
    ):
        errors.append(f"{file}: private development data")
        continue
    raw=path.read_bytes()
    if (b"\x00" in raw or raw.startswith(
        (b"\x89PNG",b"GIF87a",b"GIF89a",b"\xff\xd8\xff",b"%PDF-"))):
        errors.append(f"{file}: binary or encoded media")
        continue
    try:content=raw.decode("utf-8")
    except UnicodeDecodeError:
        errors.append(f"{file}: non-UTF8 content")
        continue
    if SECRET.search(content):
        errors.append(f"{file}: credential-like secret")
    if re.search(r"data:image/[a-z0-9+.-]+;base64,[A-Za-z0-9+/=]{80,}", content, re.I):
        errors.append(f"{file}: inline base64 image asset")
    if re.search(r"(?:iVBORw0KGgo|/9j/4AAQSk)[A-Za-z0-9+/=]{80,}", content):
        errors.append(f"{file}: embedded image payload without data URI")
    if DOC.search(file) and not lower.startswith("tests/fixtures/"):
        inside=False
        for lineno,line in enumerate(content.splitlines(),1):
            if FENCE.match(line):
                inside=not inside
                continue
            if inside:continue
            prose=INLINE.sub("",line)
            if CJK.search(prose):
                errors.append(f"{file}:{lineno}: untranslated Chinese documentation prose")
                if len(errors)>100:break
if errors:
    print("PUBLIC SAFETY GATE: FAILED",file=sys.stderr)
    for e in errors[:100]:print(" -",e,file=sys.stderr)
    sys.exit(1)
print(json.dumps({"status":"PASS","tracked_files":len(FILES),
                  "images_or_icons":0,"credential_matches":0,
                  "documentation_chinese_prose":0},indent=2))
