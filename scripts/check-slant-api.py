#!/usr/bin/env python3
"""Check Slant's live OpenAPI description against Studio's snapshot of it.

Run before every release and whenever the app's API change check fires:

    python3 -I scripts/check-slant-api.py [--update-snapshot] [--offline PATH]

1. Fetches https://slant3dapi.com/v2/api/openapi.json (public, no key, https
   only, no redirects, at most 2 MB) and prints its ETag and Last-Modified.
2. Compares it, as parsed JSON, with Sources/SlantStudio/Resources/
   slant-openapi-upstream.json (Slant's spec as last reviewed), separating
   contract changes from wording-only changes (description, summary, title,
   example and examples).
3. Checks that every difference between Studio's openapi.json and that
   snapshot is tagged with `x-slant-studio-source: docs|live` (on the changed
   node or an ancestor), or is text appended to Slant's description.

Exit codes: 0 identical, 1 contract change, 3 wording-only change, 2 untagged
patches in openapi.json (reported only when the live comparison is clean),
4 could not check (network failure, redirect, too large, unreadable JSON, bad
arguments). --update-snapshot writes the live bytes over the snapshot after
printing the diff and still exits with the diff's code.
Python 3.9+ standard library only; never sends credentials.
"""

import argparse
import hashlib
import http.client
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

SPEC_URL = "https://slant3dapi.com/v2/api/openapi.json"
MAX_BYTES = 2 * 1024 * 1024
TIMEOUT_SECONDS = 30
RESOURCES = Path(__file__).resolve().parent.parent / "Sources" / "SlantStudio" / "Resources"
SNAPSHOT = RESOURCES / "slant-openapi-upstream.json"
STUDIO_SPEC = RESOURCES / "openapi.json"
TAG = "x-slant-studio-source"
TAG_VALUES = ("docs", "live")
WORDING_KEYS = {"description", "summary", "title", "example", "examples"}
# Keys whose children are names chosen by the spec's author (a property called
# "description" is contract, not wording).
NAME_MAPS = {"paths", "properties", "schemas", "responses", "content", "headers",
             "securitySchemes", "parameters", "requestBodies", "links", "callbacks",
             "variables", "patternProperties", "mapping"}
METHODS = {"get", "put", "post", "delete", "patch", "head", "options", "trace"}
MISSING = object()
EXIT_SAME, EXIT_CONTRACT, EXIT_UNTAGGED, EXIT_WORDING, EXIT_FAILED = 0, 1, 2, 3, 4


class CheckFailed(Exception):
    pass


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise CheckFailed(f"refused a redirect ({code}) to {newurl}")


def fetch_live():
    if not SPEC_URL.startswith("https://"):
        raise CheckFailed("the spec URL must be https")
    opener = urllib.request.build_opener(NoRedirects)  # no cookie or auth handlers
    request = urllib.request.Request(SPEC_URL, headers={"Accept": "application/json",
                                                        "User-Agent": "SlantStudio-api-check"})
    try:
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            if response.status != 200:
                raise CheckFailed(f"HTTP {response.status}")
            length = response.headers.get("Content-Length")
            if length and length.isdigit() and int(length) > MAX_BYTES:
                raise CheckFailed(f"the spec is {length} bytes, over the {MAX_BYTES}-byte cap")
            body = response.read(MAX_BYTES + 1)
            if len(body) > MAX_BYTES:
                raise CheckFailed(f"the spec is over the {MAX_BYTES}-byte cap")
            return body, response.headers
    except urllib.error.HTTPError as error:
        raise CheckFailed(f"HTTP {error.code} {error.reason}") from None
    except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
        raise CheckFailed(f"could not fetch {SPEC_URL}: {getattr(error, 'reason', error)}") from None


def parse(data, label):
    try:
        document = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise CheckFailed(f"{label} is not valid JSON: {error}") from None
    if not isinstance(document, dict) or not isinstance(document.get("paths"), dict):
        raise CheckFailed(f"{label} is not an OpenAPI document (no paths)")
    return document


# ---------------------------------------------------------------------------
# Locations: turn a key path into a group ("GET /orders") and a readable place.

def group_and_place(keys):
    keys = list(keys)
    if keys[:1] == ["paths"] and len(keys) >= 2:
        if len(keys) >= 3 and keys[2] in METHODS:
            return f"{keys[2].upper()} {keys[1]}", place(keys[3:])
        return f"Path {keys[1]}", place(keys[2:])
    if keys[:2] == ["components", "schemas"] and len(keys) >= 3:
        return f"Schema {keys[2]}", place(keys[3:])
    if keys[:1] == ["components"] and len(keys) >= 3:
        return f"Component {keys[1]} {keys[2]}", place(keys[3:])
    return "Document", place(keys)


def place(keys):
    parts, i = [], 0
    while i < len(keys):
        key = keys[i]
        follower = keys[i + 1] if i + 1 < len(keys) else None
        if key in ("properties", "responses", "parameters", "content") and follower is not None:
            if key == "properties":  # say "property" where the name could be read as a keyword
                keyword_like = follower in WORDING_KEYS or follower in {"type", "format", "enum", "required", "default"}
                parts.append(f"property {follower}" if keyword_like else str(follower))
            elif key == "responses":
                parts.append(f"response {follower}")
            elif key == "parameters":
                parts.append(f"parameter {follower}")
            elif follower != "application/json":
                parts.append(str(follower))
            i += 2
            continue
        if key == "items" and parts:
            parts[-1] += "[]"
        elif key == "requestBody":
            parts.append("request body")
        elif key != "schema":
            parts.append(str(key))
        i += 1
    return " › ".join(parts) if parts else "(whole)"


def canonical(value):
    """Compare JSON values strictly: in Python, 1 == 1.0 == True."""
    return json.dumps(value, sort_keys=True)


def same(a, b):
    return canonical(a) == canonical(b)


def short(value, limit=90):
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def parameter_key(parameter):
    if isinstance(parameter, dict) and "$ref" in parameter:
        return parameter["$ref"]
    if isinstance(parameter, dict):
        return f"{parameter.get('name')} ({parameter.get('in')})"
    return short(parameter)


def keyed_parameters(value):
    if isinstance(value, list) and all(isinstance(p, dict) for p in value):
        keyed = {parameter_key(p): p for p in value}
        if len(keyed) == len(value):
            return keyed
    return None


# ---------------------------------------------------------------------------
# Live spec against the snapshot.

def diff(old, new, keys=(), names=False, out=None, wording=False):
    """Collect (keys, message, wording) for every difference from old to new."""
    out = [] if out is None else out
    if isinstance(old, dict) and isinstance(new, dict):
        child_names = bool(keys) and not names and keys[-1] in NAME_MAPS
        for key in sorted(set(old) | set(new), key=str):
            here = keys + (key,)
            is_wording = wording or (not child_names and key in WORDING_KEYS)
            if key not in new:
                out.append((here, f"removed (was {short(old[key])})", is_wording))
            elif key not in old:
                out.append((here, f"added {short(new[key])}", is_wording))
            else:
                diff(old[key], new[key], here, child_names, out, is_wording)
        return out
    if keys and keys[-1] == "parameters" and not names:
        old_keyed, new_keyed = keyed_parameters(old), keyed_parameters(new)
        if old_keyed is not None and new_keyed is not None:
            if list(old_keyed) != list(new_keyed) and set(old_keyed) == set(new_keyed):
                out.append((keys, "parameters reordered", wording))
            return _diff_named(old_keyed, new_keyed, keys, out, wording)
    if isinstance(old, list) and isinstance(new, list):
        if same(old, new):
            return out
        if all(not isinstance(v, (dict, list)) for v in old + new):
            added = [v for v in new if canonical(v) not in {canonical(o) for o in old}]
            removed = [v for v in old if canonical(v) not in {canonical(n) for n in new}]
            if not added and not removed:
                out.append((keys, f"reordered {short(old)} → {short(new)}", wording))
            else:
                text = []
                if added:
                    text.append("added " + ", ".join(short(v) for v in added))
                if removed:
                    text.append("removed " + ", ".join(short(v) for v in removed))
                out.append((keys, "; ".join(text), wording))
            return out
        if len(old) == len(new):
            for index, (a, b) in enumerate(zip(old, new)):
                diff(a, b, keys + (index,), False, out, wording)
            return out
        out.append((keys, f"list changed ({len(old)} → {len(new)} entries): {short(new)}", wording))
        return out
    if not same(old, new):
        out.append((keys, f"{short(old, 60)} → {short(new, 60)}", wording))
    return out


def _diff_named(old_keyed, new_keyed, keys, out, wording):
    for name in list(old_keyed) + [n for n in new_keyed if n not in old_keyed]:
        here = keys + (name,)
        if name not in new_keyed:
            out.append((here, "removed", wording))
        elif name not in old_keyed:
            out.append((here, f"added {short(new_keyed[name])}", wording))
        else:
            diff(old_keyed[name], new_keyed[name], here, False, out, wording)
    return out


def operations(document):
    found = set()
    for path, item in document.get("paths", {}).items():
        if isinstance(item, dict):
            found.update(f"{method.upper()} {path}" for method in item if method in METHODS)
    return found


def print_grouped(title, entries):
    print(f"\n{title} ({len(entries)}):")
    groups = {}
    for keys, message, _ in entries:
        group, where = group_and_place(keys)
        groups.setdefault(group, []).append(f"{where}: {message}")
    for group in sorted(groups):
        print(f"  {group}")
        for line in groups[group]:
            print(f"    - {line}")


def compare_with_snapshot(snapshot, live):
    old_ops, new_ops = operations(snapshot), operations(live)
    entries = diff(snapshot, live)
    contract = [e for e in entries if not e[2]]
    wording = [e for e in entries if e[2]]
    if new_ops - old_ops or old_ops - new_ops:
        print("\nOperations:")
        for op in sorted(new_ops - old_ops):
            print(f"  + {op}")
        for op in sorted(old_ops - new_ops):
            print(f"  - {op}")
    # Whole paths and operations added or removed are listed above already.
    listed = [e for e in contract if e[0][:1] == ("paths",)
              and (len(e[0]) == 2 or (len(e[0]) == 3 and e[0][2] in METHODS))]
    if len(listed) < len(contract):
        print_grouped("Contract changes", [e for e in contract if e not in listed])
    if wording:
        print_grouped("Wording-only changes", wording)
    if contract:
        return EXIT_CONTRACT
    return EXIT_WORDING if wording else EXIT_SAME


# ---------------------------------------------------------------------------
# Studio's patched spec against the snapshot.

def contains_tag(value):
    if isinstance(value, dict):
        return TAG in value or any(contains_tag(v) for v in value.values())
    return isinstance(value, list) and any(contains_tag(v) for v in value)


def untagged_patches(studio, upstream, keys=(), names=False, out=None, tagged=None):
    """Differences in Studio's spec that sit under no x-slant-studio-source tag.

    `upstream` is MISSING where Slant's snapshot has nothing at that place."""
    out = [] if out is None else out
    tagged = {} if tagged is None else tagged
    if isinstance(studio, dict) and TAG in studio:
        source = studio[TAG]
        if source not in TAG_VALUES:
            out.append((keys, f"{TAG} is {short(source)}; use docs or live"))
        elif upstream is MISSING or not same(studio, upstream):
            tagged[source] = tagged.get(source, 0) + 1
        return out
    if upstream is MISSING and not contains_tag(studio):
        out.append((keys, f"added without a tag: {short(studio, 60)}"))
        return out
    if isinstance(studio, dict) and (upstream is MISSING or isinstance(upstream, dict)):
        upstream = {} if upstream is MISSING else upstream
        child_names = bool(keys) and not names and keys[-1] in NAME_MAPS
        for key in sorted(set(studio) | set(upstream), key=str):
            here = keys + (key,)
            if key not in studio:
                out.append((here, "removed without a tag on its parent"))
            elif (key == "description" and not child_names and isinstance(studio[key], str)
                  and isinstance(upstream.get(key, ""), str) and studio[key].startswith(upstream.get(key, ""))):
                continue  # Slant's text kept, Studio's note appended
            else:
                untagged_patches(studio[key], upstream.get(key, MISSING), here, child_names, out, tagged)
        return out
    if upstream is MISSING:  # a new list holding tagged entries
        for index, value in enumerate(studio):
            untagged_patches(value, MISSING, keys + (index,), False, out, tagged)
        return out
    if keys and keys[-1] == "parameters" and not names:
        studio_keyed, upstream_keyed = keyed_parameters(studio), keyed_parameters(upstream)
        if studio_keyed is not None and upstream_keyed is not None:
            for name in upstream_keyed:
                if name not in studio_keyed:
                    out.append((keys + (name,), "removed without a tag on its parent"))
            for name, parameter in studio_keyed.items():
                untagged_patches(parameter, upstream_keyed.get(name, MISSING), keys + (name,), False, out, tagged)
            return out
    if isinstance(studio, list) and isinstance(upstream, list) and len(studio) == len(upstream):
        for index, (a, b) in enumerate(zip(studio, upstream)):
            untagged_patches(a, b, keys + (index,), False, out, tagged)
        return out
    if not same(studio, upstream):
        out.append((keys, f"{short(upstream, 60)} → {short(studio, 60)} without a tag"))
    return out


def check_patches(studio, snapshot):
    tagged = {}
    problems = untagged_patches(studio, snapshot, tagged=tagged)
    counts = ", ".join(f"{source} {count}" for source, count in sorted(tagged.items())) or "none"
    print(f"\nStudio's openapi.json against the snapshot: tagged patches ({counts}).")
    lost = sorted(operations(snapshot) - operations(studio))
    for op in lost:
        print(f"  Studio's spec has lost {op}")
    if not problems:
        print("  Every other difference is tagged or appended description text.")
        return not lost
    print(f"  Untagged patches ({len(problems)}):")
    for keys, message in problems:
        group, where = group_and_place(keys)
        print(f"    - {group} › {where}: {message}")
    return False


# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--update-snapshot", action="store_true",
                        help="after printing the diff, write the live bytes over the snapshot")
    parser.add_argument("--offline", metavar="PATH", type=Path,
                        help="compare this file instead of fetching the live spec")
    parser.add_argument("--snapshot", metavar="PATH", type=Path, default=SNAPSHOT, help=argparse.SUPPRESS)
    parser.add_argument("--studio-spec", metavar="PATH", type=Path, default=STUDIO_SPEC, help=argparse.SUPPRESS)
    parser.error = lambda message: (print(f"error: {message}", file=sys.stderr), sys.exit(EXIT_FAILED))
    args = parser.parse_args(argv)
    if args.offline and args.update_snapshot:
        parser.error("--update-snapshot writes only a live fetch; drop --offline")

    try:
        snapshot_bytes = args.snapshot.read_bytes()
        snapshot = parse(snapshot_bytes, str(args.snapshot))
        studio = parse(args.studio_spec.read_bytes(), str(args.studio_spec))
        if args.offline:
            live_bytes = args.offline.read_bytes()
            if len(live_bytes) > MAX_BYTES:
                raise CheckFailed(f"{args.offline} is over the {MAX_BYTES}-byte cap")
            print(f"Comparing {args.offline} (offline) with the snapshot.")
        else:
            live_bytes, headers = fetch_live()
            print(f"Live spec: {SPEC_URL}")
            print(f"  ETag: {headers.get('ETag', '(none)')}")
            print(f"  Last-Modified: {headers.get('Last-Modified', '(none)')}")
        live = parse(live_bytes, "the live spec")
    except (CheckFailed, OSError) as error:
        sys.stdout.flush()
        print(f"Could not check: {error}", file=sys.stderr)
        return EXIT_FAILED

    print(f"  {len(live_bytes)} bytes, sha256 {hashlib.sha256(live_bytes).hexdigest()[:16]}…; "
          f"snapshot sha256 {hashlib.sha256(snapshot_bytes).hexdigest()[:16]}…")
    if live_bytes == snapshot_bytes:
        print("Identical to the snapshot, byte for byte.")
        code = EXIT_SAME
    elif same(live, snapshot):
        print("Same content as the snapshot; only formatting differs.")
        code = EXIT_SAME
    else:
        code = compare_with_snapshot(snapshot, live)

    updated = args.update_snapshot and live_bytes != snapshot_bytes
    if updated:
        try:
            args.snapshot.write_bytes(live_bytes)
        except OSError as error:
            print(f"Could not write the snapshot: {error}", file=sys.stderr)
            return EXIT_FAILED
        snapshot = live
        print(f"\nWrote the live spec over {args.snapshot}; openapi.json is checked against it below.")

    patches_clean = check_patches(studio, snapshot)
    next_step = ("bring openapi.json, Studio and docs/API_REFERENCE.md into line until this check exits 0"
                 if updated else "run again with --update-snapshot, then bring openapi.json and Studio into line")
    if code == EXIT_CONTRACT:
        print(f"\nResult: Slant's contract changed. Read the diff; {next_step}.")
    elif code == EXIT_WORDING:
        print(f"\nResult: Slant changed only wording. Read it; {next_step}.")
    elif not patches_clean:
        print("\nResult: no change on Slant's side, but openapi.json has untagged patches.")
        code = EXIT_UNTAGGED
    else:
        print("\nResult: no change; openapi.json's patches are all tagged.")
    return code


if __name__ == "__main__":
    sys.exit(main())
