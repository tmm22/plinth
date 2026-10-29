#!/usr/bin/env python3
"""Check Slant's live OpenAPI description against Studio's snapshot of it.

Run before every release and whenever the app's API change check fires:

    python3 -I scripts/check-slant-api.py [--update-snapshot] [--offline PATH]
    python3 -I scripts/check-slant-api.py --self-test

1. Fetches https://slant3dapi.com/v2/api/openapi.json (public, no key, https
   only, no redirects, at most 2 MB) and prints its ETag and Last-Modified.
2. Compares it, as parsed JSON, with Sources/SlantStudio/Resources/
   slant-openapi-upstream.json (Slant's spec as last reviewed), separating
   contract changes from wording-only changes (description, summary, title,
   example, examples and externalDocs, the keys the app's daily check
   ignores), with the app's rules: keys inside name maps (properties, paths,
   schemas, encoding and the like) are names, never wording; `enum`,
   `default` and `const` are data, compared exactly (an enum as a set);
   unordered lists (required, tags, type, allOf and every other list but
   servers and prefixItems) are compared as sets; 1 and 1.0 are equal. The
   script also reports what the app ignores: `x-` extensions outside name
   maps, `info` other than its version, the top-level tags list, parameter
   order and path items without operations; the output says which contract
   changes those are.
3. Checks that every difference between Studio's openapi.json and that
   snapshot is tagged with `x-slant-studio-source: docs|live` on the changed
   node or an ancestor, or is text appended to Slant's own non-empty
   description (a description where Slant has none needs a tag). A
   tag at the document root or directly inside a name map (where it would
   read as a path or property name) is itself reported and exempts nothing.

Exit codes: 0 identical, 1 contract change, 3 wording-only change, 2 untagged
patches in openapi.json (reported only when the live comparison is clean),
4 could not check (network failure, redirect, too large, unreadable JSON, bad
arguments). --update-snapshot writes the live bytes over the snapshot after
printing the diff and still exits with the diff's code. --self-test runs the
comparison on built-in fixtures in a temporary folder, sends no request, and
exits 0 if every case passes, else 1.
Python 3.9+ standard library only; never sends credentials.
"""

import argparse
import contextlib
import hashlib
import http.client
import io
import json
import sys
import tempfile
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
# WORDING_KEYS, ORDERED_LIST_KEYS, NAME_MAPS, DATA_KEYS and METHODS mirror SlantAPIChanges.swift, and
# SlantAPIScriptParityTests compares them with it: change both together. Wording: `slantAPIIgnoredKeys`.
WORDING_KEYS = {"description", "summary", "title", "example", "examples", "externalDocs"}
# Lists whose order means something (`slantAPIOrderedArrayKeys`); every other list is compared as a set.
ORDERED_LIST_KEYS = {"servers", "prefixItems"}
# Keys whose children are names chosen by the spec's author (`slantAPINameMapKeys`): a property called
# "description" is contract, not wording.
NAME_MAPS = {"paths", "properties", "patternProperties", "schemas", "responses", "content", "headers",
             "securitySchemes", "parameters", "requestBodies", "links", "callbacks", "encoding", "variables",
             "mapping", "definitions", "$defs", "dependentSchemas", "webhooks", "scopes", "pathItems"}
# Values that are data, not schema (`slantAPIDataKeys`): compared exactly, an enum as a set of exact values.
DATA_KEYS = {"enum", "default", "const"}
# `slantAPIMethods`.
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
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
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


def _plain_numbers(value):
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, dict):
        return {key: _plain_numbers(child) for key, child in value.items()}
    if isinstance(value, list):
        return [_plain_numbers(child) for child in value]
    return value


def canonical(value):
    """Compare JSON values strictly (in Python, 1 == True), except that 1 and 1.0 are equal, as in the app, whose
    JSONSerialization writes both as 1."""
    return json.dumps(_plain_numbers(value), sort_keys=True)


def is_name_map(keys, names):
    """Whether the dict at `keys` holds names (paths, properties…) rather than keywords. `names` says whether the
    dict's own key is such a name: the children of a named thing are keywords again."""
    return bool(keys) and not names and keys[-1] in NAME_MAPS


def name_flags(keys):
    """For each key of a path, whether it is a name chosen by the spec's author (a child of a name map)."""
    flags = []
    for index, key in enumerate(keys):
        flags.append(index > 0 and not flags[-1] and isinstance(keys[index - 1], str) and keys[index - 1] in NAME_MAPS)
    return flags


def contract_form(value, keys=(), names=False):
    """A value as the contract comparison sees it: wording removed outside name maps, data kept exactly, unordered
    lists sorted. Used only to pair the entries of a reordered list."""
    if isinstance(value, dict):
        child_names = is_name_map(keys, names)
        result = {}
        for key, child in value.items():
            if not child_names and key in WORDING_KEYS:
                continue
            if not child_names and key in DATA_KEYS:
                result[key] = sorted(child, key=canonical) if key == "enum" and isinstance(child, list) else child
            else:
                result[key] = contract_form(child, keys + (key,), child_names)
        return result
    if isinstance(value, list):
        items = [contract_form(child, keys + (index,)) for index, child in enumerate(value)]
        return items if keys and keys[-1] in ORDERED_LIST_KEYS else sorted(items, key=canonical)
    return value


def paired_by_contract(old, new):
    """Pair the entries of two unordered lists that hold the same entries once wording is set aside, keeping
    unmoved entries in place; None if they don't."""
    old_forms = [canonical(contract_form(v)) for v in old]
    new_forms = [canonical(contract_form(v)) for v in new]
    if sorted(old_forms) != sorted(new_forms):
        return None
    unused = list(range(len(old)))
    pairs = [None] * len(new)
    for index, form in enumerate(new_forms):  # first the entries that stayed where they were
        if index < len(old) and old_forms[index] == form:
            pairs[index] = index
            unused.remove(index)
    for index, form in enumerate(new_forms):
        if pairs[index] is None:
            match = next(i for i in unused if old_forms[i] == form)
            pairs[index] = match
            unused.remove(match)
    return [(index, old[match], new[index]) for index, match in enumerate(pairs)]


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
        child_names = is_name_map(keys, names)
        for key in sorted(set(old) | set(new), key=str):
            here = keys + (key,)
            is_wording = wording or (not child_names and key in WORDING_KEYS)
            if key not in new:
                out.append((here, f"removed (was {short(old[key])})", is_wording))
            elif key not in old:
                out.append((here, f"added {short(new[key])}", is_wording))
            elif not child_names and key in DATA_KEYS:
                diff_data(old[key], new[key], here, out, is_wording)
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
        ordered = bool(keys) and keys[-1] in ORDERED_LIST_KEYS
        if not ordered and sorted(canonical(v) for v in old) == sorted(canonical(v) for v in new):
            return out  # the same entries in another order: a set, as the app compares it
        if all(not isinstance(v, (dict, list)) for v in old + new):
            added = [v for v in new if canonical(v) not in {canonical(o) for o in old}]
            removed = [v for v in old if canonical(v) not in {canonical(n) for n in new}]
            if not added and not removed:
                what = "reordered" if ordered else "repeated entries changed"
                out.append((keys, f"{what} {short(old)} → {short(new)}", wording))
            else:
                text = []
                if added:
                    text.append("added " + ", ".join(short(v) for v in added))
                if removed:
                    text.append("removed " + ", ".join(short(v) for v in removed))
                out.append((keys, "; ".join(text), wording))
            return out
        pairs = None if ordered or len(old) != len(new) else paired_by_contract(old, new)
        if pairs is not None:  # reordered, and changed only in wording: compare each entry with its match
            for index, a, b in pairs:
                diff(a, b, keys + (index,), False, out, wording)
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


def diff_data(old, new, keys, out, wording):
    """`enum`, `default` and `const` hold data, not schema: compared exactly, never as wording below them, and an
    enum as a set of exact values (as the app does)."""
    if keys[-1] == "enum" and isinstance(old, list) and isinstance(new, list):
        if sorted(canonical(v) for v in old) == sorted(canonical(v) for v in new):
            return out
        old_values, new_values = {canonical(v) for v in old}, {canonical(v) for v in new}
        added = [v for v in new if canonical(v) not in old_values]
        removed = [v for v in old if canonical(v) not in new_values]
        text = []
        if added:
            text.append("added " + ", ".join(short(v) for v in added))
        if removed:
            text.append("removed " + ", ".join(short(v) for v in removed))
        out.append((keys, "; ".join(text) or f"repeated entries changed {short(old)} → {short(new)}", wording))
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


def has_operations(item):
    return isinstance(item, dict) and any(method in item for method in METHODS)


def app_ignores(entry, bare_paths=frozenset()):
    """Whether the app's daily check (SlantAPIChanges.swift) ignores this contract change: an `x-` extension outside
    a name map (an `x-request-id` header is a name, and compared), `info` other than its version, the top-level tags
    list, parameter order, or a path item with no operations on either side (`bare_paths`)."""
    keys, message, _ = entry
    if any(isinstance(key, str) and key.startswith("x-") and not is_name
           for key, is_name in zip(keys, name_flags(keys))):
        return True
    if keys[:1] == ("info",) and keys[:2] != ("info", "version"):
        return True
    if keys[:1] == ("tags",):
        return True
    if keys[:1] == ("paths",) and len(keys) >= 2 and keys[1] in bare_paths:
        return True
    return message == "parameters reordered"


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
    old_paths, new_paths = snapshot.get("paths", {}), live.get("paths", {})
    # Path items holding no operation (only shared parameters, say): the app compares nothing in them.
    bare_paths = frozenset(path for path in set(old_paths) | set(new_paths)
                           if not has_operations(old_paths.get(path)) and not has_operations(new_paths.get(path)))
    bare_added = sorted(p for p in bare_paths if p in new_paths and p not in old_paths)
    bare_removed = sorted(p for p in bare_paths if p in old_paths and p not in new_paths)
    entries = diff(snapshot, live)
    contract = [e for e in entries if not e[2]]
    wording = [e for e in entries if e[2]]
    if new_ops - old_ops or old_ops - new_ops or bare_added or bare_removed:
        print("\nOperations:")
        for op in sorted(new_ops - old_ops):
            print(f"  + {op}")
        for op in sorted(old_ops - new_ops):
            print(f"  - {op}")
        for path in bare_added:
            print(f"  + Path {path} (no operations; the app's daily check ignores it)")
        for path in bare_removed:
            print(f"  - Path {path} (no operations; the app's daily check ignores it)")
    # Whole paths and operations added or removed are listed above already.
    added_or_removed_paths = set(old_paths) ^ set(new_paths)

    def listed(entry):
        keys = entry[0]
        if keys[:1] != ("paths",):
            return False
        if len(keys) == 2:
            return keys[1] in added_or_removed_paths
        return len(keys) == 3 and keys[2] in METHODS and (f"{keys[2].upper()} {keys[1]}" in old_ops ^ new_ops)

    unlisted = [e for e in contract if not listed(e)]
    if unlisted:
        print_grouped("Contract changes", unlisted)
        ignored = [e for e in unlisted if app_ignores(e, bare_paths)]
        if ignored:
            print(f"  Note: {len(ignored)} of these ({', '.join(sorted({group_and_place(e[0])[0] for e in ignored}))}) "
                  "are `x-` extension, `info`, top-level tags, parameter-order or operation-less path changes. This "
                  "script reports them, but the app's daily check ignores them, so the app shows no notice for them.")
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
    child_names = is_name_map(keys, names)
    if isinstance(studio, dict) and TAG in studio and (child_names or not keys):
        # Inside a name map the tag reads as a path or property name, and at the root it would exempt the whole
        # spec: report it, and check everything below as untagged.
        where = "at the document root" if not keys else f"directly inside `{keys[-1]}`, whose keys are names"
        out.append((keys + (TAG,), f"the tag is placed {where}; put it on the entry that holds the fact"))
        studio = {key: value for key, value in studio.items() if key != TAG}
    elif isinstance(studio, dict) and TAG in studio:
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
        for key in sorted(set(studio) | set(upstream), key=str):
            here = keys + (key,)
            if key not in studio:
                out.append((here, "removed without a tag on its parent"))
            elif (key == "description" and not child_names and isinstance(studio[key], str)
                  and isinstance(upstream.get(key), str) and upstream[key].strip()
                  and studio[key].startswith(upstream[key])):
                continue  # Slant's text kept, Studio's note appended (a description where Slant has none needs a tag)
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

# ---------------------------------------------------------------------------
# Self-test: offline fixtures for every exit code and comparison rule.

_DELETE = object()


def _fixture_spec():
    return {
        "openapi": "3.0.3",
        "info": {"title": "Fixture", "version": "2.0.0"},
        "servers": [{"url": "https://example.invalid/v2"}],
        "tags": [{"name": "Orders"}, {"name": "Files"}],
        "paths": {
            "/orders": {"get": {
                "tags": ["Orders"], "summary": "List orders",
                "parameters": [
                    {"name": "status", "in": "query", "schema": {"type": "string", "enum": ["DRAFT", "SHIPPED"]}},
                    {"name": "page", "in": "query", "schema": {"type": "integer", "maximum": 1}}],
                "responses": {"200": {
                    "description": "OK",
                    "headers": {"x-request-id": {"schema": {"type": "string"}}},
                    "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Order"}}}}}}},
            "/files": {"post": {
                "tags": ["Files"],
                "requestBody": {"content": {"multipart/form-data": {
                    "schema": {"type": "object", "properties": {"file": {"type": "string"},
                                                                "description": {"type": "string"}}},
                    "encoding": {"description": {"contentType": "text/plain"}}}}},
                "responses": {"200": {"description": "OK", "content": {"application/json": {"schema": {"allOf": [
                    {"$ref": "#/components/schemas/Order", "description": "first"},
                    {"type": "object", "description": "second", "required": ["a", "b"]}]}}}}}}},
        },
        "components": {"schemas": {"Order": {
            "type": "object", "description": "An order.",
            "properties": {"status": {"type": "string"},
                           "tags": {"type": "array", "default": ["x", "y"]},
                           "kind": {"const": {"a": 1, "description": "kept"}}}}}},
    }


def _edited(document, *edits):
    """A deep copy of `document` with each (key path, value) set, or removed when the value is _DELETE."""
    document = json.loads(json.dumps(document))
    for path, value in edits:
        parent = document
        for key in path[:-1]:
            parent = parent[key]
        if value is _DELETE:
            del parent[path[-1]]
        else:
            parent[path[-1]] = value
    return document


def _dump(document):
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def self_test():
    global fetch_live
    real_fetch, fetches = fetch_live, []

    def refuse_fetch():
        fetches.append(True)
        raise CheckFailed("the self-test never fetches")

    fetch_live = refuse_fetch
    base = _fixture_spec()
    base_bytes = _dump(base)
    order = ("components", "schemas", "Order")
    properties = order + ("properties",)
    get_orders = ("paths", "/orders", "get")
    form = ("paths", "/files", "post", "requestBody", "content", "multipart/form-data")
    all_of = ("paths", "/files", "post", "responses", "200", "content", "application/json", "schema", "allOf")
    first, second = _edited(base)["paths"]["/files"]["post"]["responses"]["200"]["content"]["application/json"][
        "schema"]["allOf"]
    failures, count = [], 0
    try:
        with tempfile.TemporaryDirectory(prefix="slant-api-check-self-test-") as folder:
            folder = Path(folder)
            snapshot, live_path, studio_path = folder / "snapshot.json", folder / "live.json", folder / "studio.json"
            snapshot.write_bytes(base_bytes)

            def run(name, expected, live=None, studio=None, contains=(), excludes=(), live_bytes=None, argv=None,
                    old=None, old_bytes=None):
                nonlocal count
                count += 1
                snapshot_bytes = old_bytes if old_bytes is not None else _dump(old) if old else base_bytes
                snapshot.write_bytes(snapshot_bytes)
                live_path.write_bytes(live_bytes if live_bytes is not None else _dump(live) if live else base_bytes)
                studio_path.write_bytes(_dump(studio) if studio else snapshot_bytes)
                if argv is None:
                    argv = ["--offline", str(live_path), "--snapshot", str(snapshot), "--studio-spec", str(studio_path)]
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    try:
                        code = main(argv)
                    except SystemExit as exit_:
                        code = exit_.code
                    except Exception as error:  # a crash fails the case; it never ends the self-test
                        code = f"a crash ({type(error).__name__}: {error})"
                text = output.getvalue()
                problems = [f"exit {code}, expected {expected}"] if code != expected else []
                if snapshot.read_bytes() != snapshot_bytes:
                    problems.append("the snapshot was written")
                problems += [f"the output lacks {s!r}" for s in contains if s not in text]
                problems += [f"the output has {s!r}" for s in excludes if s in text]
                print(f"  {'FAIL' if problems else 'ok  '} {name}")
                if problems:
                    failures.append(name)
                    for problem in problems:
                        print(f"         {problem}")
                    print("         " + text.strip().replace("\n", "\n         "))

            print("Live spec against the snapshot:")
            run("identical bytes", EXIT_SAME, contains=["byte for byte", "all tagged"])
            run("1 and 1.0, and formatting, are the same", EXIT_SAME,
                live_bytes=json.dumps(base, indent=4).replace('"maximum": 1', '"maximum": 1.0').encode("utf-8"),
                contains=["only formatting differs"])
            run("a type change is a contract change", EXIT_CONTRACT,
                live=_edited(base, (properties + ("status", "type"), "integer")), contains=["Schema Order"])
            run("a reworded description is wording", EXIT_WORDING,
                live=_edited(base, (order + ("description",), "An order on Slant.")), contains=["Wording-only"])
            run("a reordered default is a contract change", EXIT_CONTRACT,
                live=_edited(base, (properties + ("tags", "default"), ["y", "x"])), contains=["default"])
            run("wording inside a const is data", EXIT_CONTRACT,
                live=_edited(base, (properties + ("kind", "const", "description"), "changed")),
                excludes=["Wording-only"])
            run("a reordered enum is no change", EXIT_SAME,
                live=_edited(base, (get_orders + ("parameters", 0, "schema", "enum"), ["SHIPPED", "DRAFT"])),
                excludes=["Contract changes"])
            run("a removed enum value is a contract change", EXIT_CONTRACT,
                live=_edited(base, (get_orders + ("parameters", 0, "schema", "enum"), ["DRAFT"])),
                contains=['removed "SHIPPED"'])
            run("a property named description is contract", EXIT_CONTRACT,
                live=_edited(base, (form + ("schema", "properties", "description"), _DELETE)),
                excludes=["Wording-only"])
            run("an encoding entry named description is contract", EXIT_CONTRACT,
                live=_edited(base, (form + ("encoding", "description"), _DELETE)), excludes=["Wording-only"])
            run("an x- header name is compared by the app", EXIT_CONTRACT,
                live=_edited(base, (get_orders + ("responses", "200", "headers", "x-request-id"), _DELETE)),
                excludes=["the app's daily check ignores"])
            run("an x- extension is noted as ignored by the app", EXIT_CONTRACT,
                live=_edited(base, (get_orders + ("x-internal",), True)), contains=["the app's daily check ignores"])
            run("a parameter reorder is noted as ignored by the app", EXIT_CONTRACT,
                live=_edited(base, (get_orders + ("parameters",), list(reversed(base["paths"]["/orders"]["get"][
                    "parameters"])))), contains=["parameters reordered", "the app's daily check ignores"])
            run("a path with no operations is named", EXIT_CONTRACT,
                live=_edited(base, (("paths", "/later"), {"parameters": [{"name": "id", "in": "path"}]})),
                contains=["+ Path /later (no operations"])
            later = _edited(base, (("paths", "/later"), {"parameters": [{"name": "id", "in": "path"}]}))
            run("a removed path with no operations is named", EXIT_CONTRACT, old=later,
                contains=["- Path /later (no operations"])
            run("a changed path with no operations is noted as ignored by the app", EXIT_CONTRACT, old=later,
                live=_edited(later, (("paths", "/later", "parameters", 0, "in"), "query")),
                contains=["Path /later", "the app's daily check ignores"])
            run("a removed operation is listed", EXIT_CONTRACT,
                live=_edited(base, (("paths", "/files", "post"), _DELETE)), contains=["- POST /files"])
            run("an added operation is listed", EXIT_CONTRACT,
                live=_edited(base, (("paths", "/later"), {"get": {"responses": {}}})), contains=["+ GET /later"])
            run("a reordered allOf with a reworded entry is wording", EXIT_WORDING,
                live=_edited(base, (all_of, [_edited(second, (("description",), "second, reworded")), first])),
                contains=["Wording-only"], excludes=["Contract changes"])
            run("a reordered required list inside allOf is no change", EXIT_SAME,
                live=_edited(base, (all_of + (1, "required"), ["b", "a"])), excludes=["Contract changes"])

            print("Studio's openapi.json against the snapshot:")
            tagged_type = _edited(base, (properties + ("status",), {"type": "integer", TAG: "live"}))
            run("an unchanged Studio spec", EXIT_SAME, contains=["tagged patches (none)"])
            run("an untagged patch", EXIT_UNTAGGED,
                studio=_edited(base, (properties + ("status", "type"), "integer")), contains=["without a tag"])
            run("a tagged patch", EXIT_SAME, studio=tagged_type, contains=["live 1"])
            run("a tag directly inside properties exempts nothing", EXIT_UNTAGGED,
                studio=_edited(base, (properties + (TAG,), "docs"), (properties + ("status", "type"), "integer")),
                contains=["directly inside `properties`", "without a tag"])
            run("a tag directly inside paths exempts nothing", EXIT_UNTAGGED,
                studio=_edited(base, (("paths", TAG), "live"), (get_orders + ("parameters", 1, "required"), True)),
                contains=["directly inside `paths`", "without a tag"])
            run("a tag in another name map is reported", EXIT_UNTAGGED,
                studio=_edited(base, (form + ("encoding", TAG), "docs")), contains=["directly inside `encoding`"])
            run("a tag at the root exempts nothing", EXIT_UNTAGGED,
                studio=_edited(base, ((TAG,), "docs"), (properties + ("status", "type"), "integer")),
                contains=["document root", "without a tag"])
            run("a property's own tag is allowed", EXIT_SAME,
                studio=_edited(base, (properties + ("status", TAG), "docs"),
                               (properties + ("status", "format"), "date")), contains=["docs 1"])
            run("a tag that isn't docs or live", EXIT_UNTAGGED,
                studio=_edited(base, (properties + ("status",), {"type": "integer", TAG: "guess"})),
                contains=["use docs or live"])
            run("text appended to Slant's description", EXIT_SAME,
                studio=_edited(base, (order + ("description",), "An order. Studio's note.")))
            run("a description where Slant has none needs a tag", EXIT_UNTAGGED,
                studio=_edited(base, (get_orders + ("parameters", 1, "description"), "Studio's note.")),
                contains=["parameter page (query) › description: added without a tag"])
            empty = _edited(base, (get_orders + ("parameters", 1, "description"), ""))
            run("a description where Slant's is empty needs a tag", EXIT_UNTAGGED, old=empty, live=empty,
                studio=_edited(base, (get_orders + ("parameters", 1, "description"), " Studio's note.")),
                contains=["without a tag"])
            run("a description where Slant has none, tagged on its parameter", EXIT_SAME,
                studio=_edited(base, (get_orders + ("parameters", 1, "description"), "Studio's note."),
                               (get_orders + ("parameters", 1, TAG), "live")), contains=["live 1"])
            run("an operation lost from Studio's spec", EXIT_UNTAGGED,
                studio=_edited(base, (("paths", "/files"), _DELETE)), contains=["has lost POST /files"])
            run("a tagged new operation", EXIT_SAME,
                studio=_edited(base, (("paths", "/extra"), {"get": {TAG: "docs", "responses": {}}})))
            run("a contract change outranks untagged patches", EXIT_CONTRACT,
                live=_edited(base, (properties + ("status", "type"), "number")),
                studio=_edited(base, (properties + ("status", "type"), "integer")))

            print("Could not check:")
            run("unreadable JSON", EXIT_FAILED, live_bytes=b"{not json", contains=["not valid JSON"])
            run("not an OpenAPI document", EXIT_FAILED, live_bytes=b'{"openapi": "3.0.3"}', contains=["no paths"])
            run("nested too deeply to read", EXIT_FAILED,
                live_bytes=b'{"paths": {}, "x": ' + b"[" * 100_000 + b"]" * 100_000 + b"}",
                contains=["Could not check"])
            deep = b'{"paths": {}, "x": ' + b'{"a": ' * 800 + b"%s" + b"}" * 800 + b"}"
            run("nested too deeply to compare", EXIT_FAILED, old_bytes=deep % b"1", live_bytes=deep % b"2",
                contains=["nested too deeply to compare"])
            run("over the size cap", EXIT_FAILED, live_bytes=b" " * (MAX_BYTES + 1), contains=["byte cap"])
            run("a missing file", EXIT_FAILED, argv=["--offline", str(folder / "missing.json"), "--snapshot",
                                                     str(snapshot), "--studio-spec", str(studio_path)])
            run("--offline with --update-snapshot", EXIT_FAILED,
                argv=["--offline", str(live_path), "--update-snapshot", "--snapshot", str(snapshot)])
            run("an unknown option", EXIT_FAILED, argv=["--no-such-option"])
            count += 1
            try:
                NoRedirects().redirect_request(None, None, 302, "Found", {}, "https://elsewhere.invalid/")
                failures.append("a redirect is refused")
                print("  FAIL a redirect is refused")
            except CheckFailed:
                print("  ok   a redirect is refused")
            count += 1
            if fetches:
                failures.append("nothing fetched")
                print("  FAIL nothing fetched")
            else:
                print("  ok   nothing fetched")
    finally:
        fetch_live = real_fetch
    if failures:
        print(f"\nSelf-test: {len(failures)} of {count} cases failed: {', '.join(failures)}.")
        return 1
    print(f"\nSelf-test: all {count} cases passed.")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--update-snapshot", action="store_true",
                        help="after printing the diff, write the live bytes over the snapshot")
    parser.add_argument("--offline", metavar="PATH", type=Path,
                        help="compare this file instead of fetching the live spec")
    parser.add_argument("--snapshot", metavar="PATH", type=Path, default=SNAPSHOT, help=argparse.SUPPRESS)
    parser.add_argument("--studio-spec", metavar="PATH", type=Path, default=STUDIO_SPEC, help=argparse.SUPPRESS)
    parser.add_argument("--self-test", action="store_true",
                        help="check the comparison on built-in fixtures, offline, and exit 0 if all pass, else 1")
    parser.error = lambda message: (print(f"error: {message}", file=sys.stderr), sys.exit(EXIT_FAILED))
    args = parser.parse_args(argv)
    if args.offline and args.update_snapshot:
        parser.error("--update-snapshot writes only a live fetch; drop --offline")
    if args.self_test:
        if args.offline or args.update_snapshot or args.snapshot != SNAPSHOT or args.studio_spec != STUDIO_SPEC:
            parser.error("--self-test takes no other options")
        return self_test()

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
    try:
        return report(args, snapshot_bytes, snapshot, studio, live_bytes, live)
    except RecursionError:
        sys.stdout.flush()
        print("Could not check: a spec is nested too deeply to compare", file=sys.stderr)
        return EXIT_FAILED


def report(args, snapshot_bytes, snapshot, studio, live_bytes, live):
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
