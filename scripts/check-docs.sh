#!/usr/bin/env bash
#
# Mechanical documentation checks — the part of the docs alignment gate a
# script can do (docs/architecture/release-process.md §5).
#
#   1. MOCK catalog   docs/architecture/test-cases.md carries the shared catalog
#                     block; its iOS ✅ ids equal the MOCK case ids in
#                     Demo/RTCDemo/Integration/Mock/MockTestCases.swift, in the
#                     same order and group. When the sibling repos
#                     ../avatarkit-web-rtc and ../avatarkit-android-rtc exist,
#                     their blocks must be byte-identical to this one.
#   2. Line refs      `File.ext:N` / `File.ext:N-M` / `path/File.ext:N` in
#                     README.md and docs/ (except decisions/ and history/) stay
#                     within the file's line count. A file that cannot be
#                     located uniquely in this repo (e.g. one in the main SDK)
#                     is SKIP, not FAIL.
#   3. docs-map       every .md under docs/ is registered in
#                     docs/architecture/docs-map.md.
#
# docs/decisions/ and docs/history/ content is never checked (ADRs are
# immutable), but both are registered in docs-map.
#
#   4. Markdown links: every relative [text](target) in README.md and docs/**/*.md
#      resolves to an existing file (targets outside the repo are SKIPped).
#   5. release-process.md carries the core sections shared by the three RTC repos
#      (§1–§7 incl. 4.1–4.4 and 6.1) in order, here and in any sibling repo present.
#
# Prints `PASS|FAIL|SKIP <check>: <value>` per check; exit code is non-zero
# when any check fails.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, re, sys

ROOT = os.getcwd()
TEST_CASES = "docs/architecture/test-cases.md"
DOCS_MAP = "docs/architecture/docs-map.md"
MOCK_SOURCE = "Demo/RTCDemo/Integration/Mock/MockTestCases.swift"
SIBLINGS = ["avatarkit-web-rtc", "avatarkit-android-rtc"]
BEGIN, END = "<!-- mock-catalog:begin -->", "<!-- mock-catalog:end -->"
PLATFORM_COLUMN = "ios"

fails = 0
def report(status, name, value):
    global fails
    if status == "FAIL":
        fails += 1
    print(f"{status} {name}: {value}")

def catalog_block(path):
    """The block from the begin marker line to the end marker line, inclusive."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    b, e = text.find(BEGIN), text.find(END)
    if b < 0 or e < b:
        return None
    return text[b:e + len(END)]

# ---------------------------------------------------------------------------
# 1. MOCK catalog
# ---------------------------------------------------------------------------
print("--- MOCK catalog ---")
block = catalog_block(TEST_CASES)
if block is None:
    report("FAIL", "catalog block", f"{BEGIN} … {END} not found in {TEST_CASES}")
else:
    rows = [l for l in block.splitlines() if l.startswith("|")]
    header = [c.strip() for c in rows[0].strip("|").split("|")]
    col = {name: i for i, name in enumerate(header)}
    catalog = []   # (id, group) for rows marked ✅ in this platform's column
    for line in rows[2:]:
        cells = [c.strip() for c in line.strip("|").split("|")]
        if cells[col[PLATFORM_COLUMN]] == "✅":
            catalog.append((cells[col["id"]].strip("`"), cells[col["group"]]))

    source = open(MOCK_SOURCE, encoding="utf-8").read()
    # Each `static let <name>: [TestCase] = [ … ]` array, in file order, then
    # `static let all` gives the order the runner uses.
    arrays = {}
    for m in re.finditer(r"static let (\w+): \[TestCase\] = \[(.*?)\n    \]", source, re.S):
        arrays[m.group(1)] = re.findall(
            r'TestCase\(\s*id:\s*"([^"]+)".*?group:\s*"([^"]+)"', m.group(2), re.S)
    all_match = re.search(r"static let all: \[TestCase\] =(.*?)\n}", source, re.S)
    code = []
    if all_match:
        for name in re.findall(r"\w+", all_match.group(1)):
            code.extend(arrays.get(name, []))

    if not code:
        report("FAIL", "catalog vs code", f"no MOCK cases parsed from {MOCK_SOURCE}")
    elif [i for i, _ in code] == [i for i, _ in catalog]:
        report("PASS", "catalog ids vs MockTestCases.all",
               f"{len(code)} ids, same order")
    else:
        cat_ids, code_ids = [i for i, _ in catalog], [i for i, _ in code]
        missing = [i for i in cat_ids if i not in code_ids]
        extra = [i for i in code_ids if i not in cat_ids]
        first = next((n for n, (a, b) in enumerate(zip(cat_ids, code_ids)) if a != b), None)
        detail = []
        if missing: detail.append(f"in catalog, not in code: {', '.join(missing)}")
        if extra: detail.append(f"in code, not in catalog: {', '.join(extra)}")
        if not missing and not extra and first is not None:
            detail.append(f"order differs at #{first + 1}: catalog {cat_ids[first]} vs code {code_ids[first]}")
        report("FAIL", "catalog ids vs MockTestCases.all", "; ".join(detail))

    if code:
        cat_group = dict(catalog)
        wrong = [f"{i} ({g} vs catalog {cat_group[i]})" for i, g in code
                 if i in cat_group and cat_group[i] != g]
        if wrong:
            report("FAIL", "catalog groups vs code", "; ".join(wrong))
        else:
            report("PASS", "catalog groups vs code", "every group matches")

    parent = os.path.dirname(ROOT)
    for sibling in SIBLINGS:
        repo = os.path.join(parent, sibling)
        name = f"catalog identical to {sibling}"
        if not os.path.isdir(repo):
            report("SKIP", name, f"../{sibling} not present")
            continue
        other = catalog_block(os.path.join(repo, TEST_CASES))
        if other is None:
            report("FAIL", name, f"no catalog block in ../{sibling}/{TEST_CASES}")
        elif other == block:
            report("PASS", name, "byte-identical")
        else:
            report("FAIL", name, f"block differs from ../{sibling}/{TEST_CASES}")
print()

# ---------------------------------------------------------------------------
# 2. Line references
# ---------------------------------------------------------------------------
print("--- Line references ---")
SKIP_DIRS = {".git", ".build", ".swiftpm", "dist", "DerivedData", "build", "xcuserdata"}
repo_files = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.endswith(".xcodeproj")]
    for f in filenames:
        repo_files.append(os.path.relpath(os.path.join(dirpath, f), ROOT))

def locate(ref):
    """Repo-relative path for `ref`, or (None, reason)."""
    ref = ref.lstrip("./")
    if os.path.isfile(ref):
        return ref, None
    by_suffix = [p for p in repo_files if p == ref or p.endswith("/" + ref)]
    if len(by_suffix) == 1:
        return by_suffix[0], None
    if len(by_suffix) > 1:
        return None, f"ambiguous ({len(by_suffix)} files)"
    base = os.path.basename(ref)
    by_name = [p for p in repo_files if os.path.basename(p) == base]
    if len(by_name) == 1 and "/" not in ref:
        return by_name[0], None
    if len(by_name) > 1:
        return None, f"ambiguous ({len(by_name)} files named {base})"
    return None, "not in this repo"

doc_files = ["README.md"]
for dirpath, dirnames, filenames in os.walk("docs"):
    rel = os.path.relpath(dirpath, "docs")
    if rel.split(os.sep)[0] in ("decisions", "history"):
        continue
    doc_files += [os.path.join(dirpath, f) for f in filenames if f.endswith(".md")]

REF = re.compile(r"(?<![\w/.-])((?:[\w.-]+/)*[\w.-]+\.[A-Za-z]\w*):(\d+)(?:-(\d+))?(?!\d)")
line_counts = {}
checked = skipped = ref_fails = 0
for doc in sorted(doc_files):
    for lineno, line in enumerate(open(doc, encoding="utf-8"), 1):
        for m in REF.finditer(line):
            ref, start = m.group(1), int(m.group(2))
            end = int(m.group(3)) if m.group(3) else start
            if ref.startswith(("http", "www.")) or "://" in line[max(0, m.start() - 8):m.start()]:
                continue
            where = f"{doc}:{lineno} {m.group(0)}"
            path, reason = locate(ref)
            if path is None:
                report("SKIP", "line-ref " + where, reason)
                skipped += 1
                continue
            if path not in line_counts:
                with open(path, "rb") as fh:
                    line_counts[path] = len(fh.read().splitlines())
            n = line_counts[path]
            checked += 1
            if start < 1 or end < start or end > n:
                report("FAIL", "line-ref " + where, f"{path} has {n} lines")
                ref_fails += 1
if ref_fails == 0:
    report("PASS", "line-refs", f"{checked} references resolved, all within their file ({skipped} skipped)")
else:
    print(f"     line-refs: {ref_fails} of {checked} resolved references out of range")
print()

# ---------------------------------------------------------------------------
# 3. docs-map
# ---------------------------------------------------------------------------
print("--- docs-map ---")
docs_map = open(DOCS_MAP, encoding="utf-8").read()
missing = []
for dirpath, _, filenames in os.walk("docs"):
    for f in sorted(filenames):
        if not f.endswith(".md"):
            continue
        rel = os.path.relpath(os.path.join(dirpath, f), "docs")
        if rel == "architecture/docs-map.md":
            continue
        # architecture/ files are linked by bare name from inside architecture/;
        # everything else must appear with its directory (e.g. decisions/README.md).
        token = f if rel.startswith("architecture/") else rel
        if token not in docs_map:
            missing.append(rel)
if missing:
    report("FAIL", "docs-map", "not registered: " + ", ".join(missing))
else:
    report("PASS", "docs-map", "every docs/**/*.md is registered")
print()


# --- Markdown links ------------------------------------------------------------
# Every relative [text](target) in README.md and docs/**/*.md must point at an
# existing file. Web URLs, mailto: and pure #anchors are not checked; a target
# outside this repo (e.g. the umbrella repo) is SKIPped.

print("== Markdown links ==")
_repo = os.path.realpath(".")
_link_re = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
_md = ["README.md"] + sorted(
    os.path.join(dp, f) for dp, _, fs in os.walk("docs") for f in fs if f.endswith(".md"))
_n, _outside, _broken = 0, 0, []
for _f in _md:
    if not os.path.exists(_f):
        continue
    _text = re.sub(r"```.*?```", "", open(_f, encoding="utf-8").read(), flags=re.S)
    for _t in _link_re.findall(_text):
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", _t) or _t.startswith("#"):
            continue
        _path = _t.split("#", 1)[0]
        if not _path:
            continue
        _res = os.path.realpath(os.path.join(os.path.dirname(_f), _path))
        if not (_res == _repo or _res.startswith(_repo + os.sep)):
            _outside += 1
            continue
        _n += 1
        if not os.path.exists(_res):
            _broken.append(f"{_f} → {_t}")
if _broken:
    report("FAIL", "markdown links resolve", f"{len(_broken)} broken: " + "; ".join(_broken[:8]))
else:
    report("PASS", "markdown links resolve", f"{_n} checked, {_outside} outside the repo skipped")
print()

# --- release-process structure -------------------------------------------------
# The three RTC repos share one section numbering for release-process.md. Each
# must carry the core sections below, in this order; extra platform-specific
# sections (e.g. iOS §6.2, §8) are allowed.

print("== release-process structure ==")
_CORE = ["1", "2", "3", "4", "4.1", "4.2", "4.3", "4.4", "5", "6", "6.1", "7"]
_RTC_REPOS = ["avatarkit-web-rtc", "avatarkit-android-rtc", "avatarkit-ios-rtc"]

def _section_numbers(path):
    nums = []
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^#{2,3} (\d+(?:\.\d+)?)\.? ", line)
        if m:
            nums.append(m.group(1))
    return nums

def _check_structure(label, path):
    if not os.path.exists(path):
        report("SKIP", f"release-process sections ({label})", f"{path} not present")
        return
    nums = _section_numbers(path)
    core = [n for n in nums if n in _CORE]
    extra = [n for n in nums if n not in _CORE]
    if core == _CORE:
        report("PASS", f"release-process sections ({label})",
               "§" + " §".join(_CORE) + (f" + platform-specific §{' §'.join(extra)}" if extra else ""))
    else:
        missing = [n for n in _CORE if n not in core]
        report("FAIL", f"release-process sections ({label})",
               f"core sections {core} (expected {_CORE} in order" + (f"; missing {missing}" if missing else "") + ")")

_self = os.path.basename(_repo)
_check_structure(_self, "docs/architecture/release-process.md")
for _sib in _RTC_REPOS:
    if _sib != _self:
        _check_structure(_sib, os.path.join("..", _sib, "docs/architecture/release-process.md"))
print()

print("All checks passed." if fails == 0 else f"{fails} check(s) failed.")
sys.exit(1 if fails else 0)
PY
