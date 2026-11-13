#!/usr/bin/env python3
"""Plinth's mutation probe: does the test suite notice when a safety rule breaks?

Each mutant plants one deliberate bug in Sources/Plinth (an exact snippet that must occur exactly once, replaced
by a broken version), runs the full `swift test`, records whether any test failed, and puts the file back.
Every mutant must be KILLED (at least one test fails). A SURVIVED mutant is a safety rule, or the call that wires
it into a flow, that no test protects. An UNVIABLE mutant didn't compile, so it proves nothing; a mutant whose
snippet no longer matches stops the probe before anything is changed. When code moves, update the snippet to the
equivalent code; never drop a mutant without a replacement.

It edits the checkout in place (SwiftPM's build folder isn't relocatable, and a cold build takes ~20 minutes):
it refuses to start unless Sources/ and Tests/ are clean, restores each file afterwards (also on Ctrl-C, SIGTERM
and exit) and stops if `git diff` shows a file wasn't restored. Don't edit files or build in this checkout while
it runs. Each mutant takes ~1.5-3 minutes; run it before a release and after changing a guarded flow
(name the mutant IDs to run only those).

Usage: python3 -I scripts/mutation-probe.py [--check] [--list] [--jobs N] [--out DIR] [IDS...]
Exit: 0 every mutant killed; 1 some survived, were unviable or timed out; 2 a snippet doesn't match;
      3 Sources/ or Tests/ not clean; 4 a file couldn't be restored.
"""
import atexit, os, re, signal, subprocess, sys, tempfile, time

# (ID, file under Sources/Plinth, exact snippet that must occur once, its broken version, what the bug means)
MUTANTS = [
    # --- Slant pay/cancel and the unknown-outcome lock ---
    ("M01", "OrdersView.swift",
     'return !orderStatusIsCancelled(normalized) && normalized != "DRAFT"',
     'return !orderStatusIsCancelled(normalized)',
     "Drafts offer Cancel again (Slant refuses it)"),
    ("M02", "OrdersView.swift",
     '    guard orderKnownStatuses.contains(normalized) else { return false }\n    // Slant refuses DELETE',
     '    // Slant refuses DELETE',
     "An unrecognised status becomes cancellable"),
    ("M03", "OrdersView.swift",
     '        if status.uppercased() != "DRAFT" { return .statusBlocked("Only drafts can be placed.") }\n',
     '',
     "Pay re-check no longer requires the order to still be a DRAFT"),
    ("M04", "OrdersView.swift",
     '        if orderUnlistedCostSignature(shown) != orderUnlistedCostSignature(latest) { return .priceChanged }\n',
     '',
     "A new tax/fee field after the review no longer stops the payment"),
    ("M05", "OrdersView.swift",
     '        if orderShippingDetails(shown) != orderShippingDetails(latest) {',
     '        if orderShippingDetails(shown) != orderShippingDetails(latest) && shown.isEmpty {',
     "Cancel re-check ignores a shipping record that changed since review"),
    ("M06", "StudioStore.swift",
     'return (400..<500).contains(status) && status != 408 && status != 409',
     'return (400..<500).contains(status) && status != 408',
     "HTTP 409 to a pay/cancel lifts the lock (should keep it)"),
    ("M07", "StudioStore.swift",
     'return (400..<500).contains(status) && status != 408 && status != 409',
     'return (400..<600).contains(status) && status != 408 && status != 409',
     "HTTP 5xx to a pay/cancel lifts the lock (should keep it)"),
    ("M08", "StudioStore.swift",
     '        return method.uppercased() != "DELETE"\n',
     '        return true\n',
     "DNS failure on a DELETE (cancel) lifts the lock"),
    ("M09", "StudioStore.swift",
     '        if orderAttentionProductionStatuses.contains(reviewed), orderFulfillmentShippedStatuses.contains(reloaded) { return false }\n',
     '',
     "Cancel sent while PRINTING, reload shows SHIPPED: lock lifted (owner decision says keep)"),
    ("M10", "StudioStore.swift",
     '    case .pay: return reloadedStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "DRAFT"',
     '    case .pay: return true',
     "Any reload lifts a pay lock, even one still showing DRAFT"),
    ("M11", "StudioStore.swift",
     '    guard !reloaded.isEmpty, let context else { return false }',
     '    guard let context else { return false }',
     "A reload with a blank status lifts the lock"),
    # --- Pay Several Drafts ---
    ("M12", "BatchPay.swift",
     '    case "": return .unclear',
     '    case "": return .placed',
     "Batch pay: 2xx with no readable status counts as placed and continues"),
    ("M13", "BatchPay.swift",
     '    default: return orderPlacedStatuses.contains(raw) ? .placed : .unrecognised(raw)',
     '    default: return .placed',
     "Batch pay: unrecognised status counts as placed and continues"),
    ("M14", "BatchPay.swift",
     '    return batchPayMarketplaceRefsMatch(left, right)\n}',
     '    _ = (left, right); return false\n}',
     "Batch pay duplicate check only matches identical keys (same sale, different item recording, paid twice)"),
    ("M15", "BatchPay.swift",
     '    if let reason = orderUnlistedCostBatchReason(orderUnlistedCosts(order)) { return reason }\n',
     '',
     "Batch pay includes a draft with an unlisted tax/fee"),
    # --- Draft create guard ---
    ("M16", "OrderTools.swift",
     '    if overflowed { return true }\n    guard !attempts.isEmpty',
     '    guard !attempts.isEmpty',
     "Create Anyway guard forgets attempts that dropped off the 5-entry list"),
    ("M17", "OrderTools.swift",
     '    if key.isEmpty { return true }\n    return attempts.contains',
     '    if key.isEmpty { return false }\n    return attempts.contains',
     "A nameless draft no longer needs Create Anyway after an unclear create"),
    ("M18", "OrderTools.swift",
     '        return ids.contains { keeping.contains($0) }',
     '        return false',
     "An order under the unknown-outcome lock on another platform is hidden (can't refresh to lift it)"),
    # --- Slant client ---
    ("M19", "APIClient.swift",
     '        result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)\n    }\n    return result',
     '        result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)\n    }\n    return text',
     "Slant error messages no longer redact keys/bearer tokens"),
    ("M20", "APIClient.swift",
     '        if path.hasSuffix("/estimate") { return true }\n        return false',
     '        return true',
     "Every POST (pay, create draft, upload) becomes auto-retryable"),
    ("M21", "APIClient.swift",
     '        date = Date(timeIntervalSince1970: value / 1000)',
     '        date = Date(timeIntervalSince1970: value)',
     "Slant X-RateLimit-Reset read as seconds instead of milliseconds"),
    ("M22", "EstimateComparison.swift",
     'let comparisonRateLimitMinimumWait: TimeInterval = 60',
     'let comparisonRateLimitMinimumWait: TimeInterval = 5',
     "429 back-off minimum drops from 60 s to 5 s"),
    # --- Upload overwrite protection ---
    ("M23", "APIClient.swift",
     '    guard let id = uploadPlaceholderFileID(placeholder), let name = protectedFiles[id] else { return nil }\n    return (id, name)',
     '    _ = (placeholder, protectedFiles); return nil',
     "Pre-PUT guard disabled: an upload can overwrite another model's Slant file"),
    ("M24", "StudioStore.swift",
     '    return words.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))',
     '    return words',
     "Upload name check becomes case-sensitive (Benchy vs benchy overwrite)"),
    # --- Network safety ---
    ("M25", "NetworkHostSafety.swift",
     '    return !(last.first.map { $0.isLetter } ?? false)',
     '    return false',
     "IPv4 literal hosts accepted for storage/download links"),
    ("M26", "NetworkHostSafety.swift",
     '    guard url.scheme?.lowercased() == "https" else',
     '    guard url.scheme != nil else',
     "Plain http storage links accepted"),
    ("M27", "NetworkHostSafety.swift",
     '    if key.count >= 4, url.absoluteString.contains(key) { return "it contains your API key" }\n',
     '',
     "Storage link containing the API key accepted"),
    # --- 3DAPI money paths ---
    ("M28", "DapiClient.swift",
     '        if let body, !operation.isMoneyWrite || body.code != nil {',
     '        if let body {',
     "3DAPI: a bare 4xx to Place Order counts as a refusal ('nothing charged')"),
    ("M29", "DapiClient.swift",
     '    if (400..<500).contains(status), status != 408 {',
     '    if (400..<500).contains(status) {',
     "3DAPI: HTTP 408 counts as a definite refusal"),
    ("M30", "DapiClient.swift",
     '       seconds.isFinite, seconds > 0, seconds < 100_000_000_000 {',
     '       seconds.isFinite, seconds > 0 {',
     "3DAPI: millisecond reset values accepted as seconds"),
    ("M31", "DapiOrderComposer.swift",
     '    if reviewed.shippingTotal != current.shippingTotal {',
     '    if reviewed.shippingTotal != current.shippingTotal && reviewed.lines.isEmpty {',
     "3DAPI: shipping price change before Place Order is ignored"),
    ("M32", "DapiOrderComposer.swift",
     '        guard before != after else { continue }',
     '        guard before == nil || after == nil else { continue }',
     "3DAPI: unit price change before Place Order is ignored"),
    ("M33", "DapiOrderComposer.swift",
     '        guard now.amountMinor > before.amountMinor else { return nil }',
     '        guard now.amountMinor < before.amountMinor else { return nil }',
     "3DAPI: a larger wallet shortfall no longer stops the order"),
    ("M34", "DapiOrderComposer.swift",
     '    case (.covered, .notKnown), (.short, .notKnown):\n        return dapiWalletNotComparableText',
     '    case (.covered, .notKnown), (.short, .notKnown):\n        return nil',
     "3DAPI: wallet that can no longer be compared no longer stops the order"),
    ("M35", "DapiOrderComposer.swift",
     '        if draftName.isEmpty || name.isEmpty || name == draftName { return true }',
     '        if name == draftName { return true }',
     "3DAPI: Place Anyway not asked when a name is missing on either side"),
    ("M36", "DapiOrderComposer.swift",
     '           reference == draftReference { return true }',
     '           reference == draftReference { return false }',
     "3DAPI: Place Anyway not asked for the same seller reference"),
    ("M37", "DapiOrderComposer.swift",
     '    addressIsSellersOwn && dapiWalletShowsSampleCredit(wallet)',
     '    dapiWalletShowsSampleCredit(wallet)',
     "3DAPI: sample credit pre-ticked for customer orders, not just the seller's own address"),
    # --- Claude-written OpenSCAD gate ---
    ("M38", "ScadSafety.swift",
     '    if scan.usesFileArgument {',
     '    if scan.usesFileArgument && code.isEmpty {',
     "OpenSCAD gate allows `file =` arguments"),
    ("M39", "ScadSafety.swift",
     '    if scadSafetyHasLoneCarriageReturn(code) {',
     '    if scadSafetyHasLoneCarriageReturn(code) && code.isEmpty {',
     "OpenSCAD gate allows lone carriage returns (comment smuggling)"),
    ("M40", "ScadSafety.swift",
     '    for word in scadSafetyFileReadingWords where scan.identifiers.contains(word) {',
     '    for word in scadSafetyFileReadingWords where scan.identifiers.contains(word) && word != "import" {',
     "OpenSCAD gate allows import()"),
    # --- Shopify ---
    ("M41", "ShopifyClient.swift",
     '    if root["data"] is [String: Any] { return true }\n',
     '',
     "Shopify: a mutation reply with data and an error code counts as refused (may have run)"),
    # --- Geometry / carriers / metadata ---
    ("M42", "MeshRepair.swift",
     '    meshHealthIsSound(before) && !meshHealthIsSound(after)',
     '    meshHealthIsSound(before) && !meshHealthIsSound(after) && before.triangleCount < 0',
     "Mesh tools may save a copy worse than its input"),
    ("M43", "CarrierTracking.swift",
     '    if check == 10 { check = 0 } else if check == 11 { check = 5 }',
     '    if check == 10 { check = 0 } else if check == 11 { check = 0 }',
     "S10 postal check digit wrong for the mod-11 = 11 case"),
    ("M44", "CarrierTracking.swift",
     '    for (index, digit) in body.reversed().enumerated() { total += digit * (index % 2 == 0 ? 3 : 1) }',
     '    for (index, digit) in body.reversed().enumerated() { total += digit * (index % 2 == 0 ? 1 : 3) }',
     "GS1 (USPS) check digit weights swapped"),
    ("M45", "DraftConfirmation.swift",
     'studioDraftMarkerKey), metadata.count < orderMetadataFieldLimit else { return metadata }',
     'studioDraftMarkerKey), metadata.count <= orderMetadataFieldLimit else { return metadata }',
     "Draft marker added even when metadata is already full (off-by-one)"),
]

# Wiring: the calls that put those rules into the Slant money and upload flows. Deleting any of these left every
# test green until round 25 moved the flows behind injectable environments (SlantOrderWrite.swift,
# OrderDraftSender.swift, the guard inside APIClient.upload).
MUTANTS += [
    ("W01", "SlantOrderWrite.swift",
     '    if let abort = orderConfirmRecheckAbortError(record.outcome) { throw abort }\n',
     '',
     "Single pay/cancel review: the fresh re-check's result is ignored before the write"),
    ("W02", "SlantOrderWrite.swift",
     '    if env.isOutcomeUnknown(orderID) { throw StudioError(unknownOutcomeBlockMessage) }\n',
     '',
     "Single pay/cancel review: sends while that order's outcome is unknown"),
    ("W03", "SlantOrderWrite.swift",
     '    env.markOutcomeUnknown(orderID, isPay ? .pay : .cancel, latest["status"] as? String)\n',
     '',
     "Single pay/cancel review: the lock is never recorded before the write"),
    ("W04", "SlantOrderWrite.swift",
     '    if let abort = orderConfirmRecheckAbortError(orderConfirmRecheck(method: "POST", shown: reviewed, latest: latest)) {',
     '    if let abort = orderConfirmRecheckAbortError(orderConfirmRecheck(method: "POST", shown: reviewed, latest: latest)), reviewed.isEmpty {',
     "Pay Several Drafts: the fresh re-check is skipped before each pay"),
    ("W05", "SlantOrderWrite.swift",
     '    if env.isOutcomeUnknown(id) { return (.notSent(unknownOutcomeBlockMessage), nil, nil) }\n',
     '',
     "Pay Several Drafts: pays an order whose outcome is unknown"),
    ("W06", "SlantOrderWrite.swift",
     '        return BatchPayReviewedDraft(id: id, order: order, exclusion: alreadyPaid ?? reason)',
     '        _ = reason\n        return BatchPayReviewedDraft(id: id, order: order, exclusion: alreadyPaid)',
     "Pay Several Drafts: exclusion reasons are worked out but not applied"),
    ("W06b", "SlantOrderWrite.swift",
     '        guard draft.payable, let reason = duplicates[draft.id] else { return draft }',
     '        guard draft.payable, let reason = duplicates[draft.id], draft.id.isEmpty else { return draft }',
     "Pay Several Drafts: marketplace duplicates are not left out"),
    ("W06c", "SlantOrderWrite.swift",
     '            guard draft.payable, let reason = unchecked[draft.id] else { return draft }',
     '            guard draft.payable, let reason = unchecked[draft.id], draft.id.isEmpty else { return draft }',
     "Pay Several Drafts: unchecked marketplace orders are not left out"),
    ("W07", "APIClient.swift",
     '        try uploadPlaceholderGuard(placeholder, protectedFiles: protectedFiles, replacing: replacing)',
     '        if placeholder.isEmpty { try uploadPlaceholderGuard(placeholder, protectedFiles: protectedFiles, replacing: replacing) }',
     "Uploads: the pre-PUT overwrite guard is never run"),
    ("W08", "BatchPersonalise.swift",
     'protectedFiles: protected, replacing: nil) { _ in }',
     'protectedFiles: [:], replacing: nil) { _ in }',
     "Personalised uploads: nothing is protected from being overwritten"),
    ("W09", "StudioStore.swift",
     'protectedFiles: guarded, replacing: replacing,',
     'protectedFiles: [:], replacing: replacing,',
     "Models uploads: nothing is protected from being overwritten (a source check catches this)"),
    ("W10", "OrderDraftSender.swift",
     '        if draftCreateNeedsConfirmation(outcomeUnknown: needsCreateAnyway, confirmed: confirmedDespiteUnknownOutcome) {',
     '        if draftCreateNeedsConfirmation(outcomeUnknown: needsCreateAnyway && false, confirmed: confirmedDespiteUnknownOutcome) {',
     "Create Draft: Create Anyway is never asked after an unclear create"),
    ("W11", "SlantOrderWrite.swift",
     '            isOutcomeUnknown: { store.isOutcomeUnknown(orderID: $0) },',
     '            isOutcomeUnknown: { _ in false },',
     "The app's order-write environment never sees the lock (a source check catches this)"),
    ("W12", "SlantOrderWrite.swift",
     '            markOutcomeUnknown: { store.markOutcomeUnknown(orderID: $0, action: $1, reviewedStatus: $2) },',
     '            markOutcomeUnknown: { _, _, _ in },',
     "The app's order-write environment never records the lock (a source check catches this)"),
    ("W13", "BatchPay.swift",
     'lockedIDs: store.unknownOutcomeOrderIDs, placedIDs: placedIDs,',
     'lockedIDs: [], placedIDs: placedIDs,',
     "Pay Several Drafts' review ignores locked orders (a source check catches this)"),
    ("W14", "BatchPay.swift",
     'listed: store.orders, recentPlaced: recent?.orders(forKey: reviewedKey) ?? [],',
     'listed: [], recentPlaced: recent?.orders(forKey: reviewedKey) ?? [],',
     "Pay Several Drafts' duplicate check ignores the loaded orders (a source check catches this)"),
]


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO, "Sources", "Plinth")
FAIL_RE = re.compile(r"(?:Test Case '-|error: -)\[PlinthTests\.(\w+) (\w+)\]'?(?: failed| :)")
SWIFT_TESTING_FAIL_RE = re.compile(r"Test (\S+?)\(\) .*failed")
STARTED = "Test Suite 'All tests' started"


def parse_args(argv):
    opts = {"check": False, "list": False, "jobs": "3", "out": None, "ids": []}
    it = iter(argv)
    for arg in it:
        if arg == "--check": opts["check"] = True
        elif arg == "--list": opts["list"] = True
        elif arg == "--jobs": opts["jobs"] = next(it)
        elif arg == "--out": opts["out"] = next(it)
        elif arg.startswith("-"): sys.exit(f"Unknown option {arg}")
        else: opts["ids"].append(arg)
    return opts


def read(path):
    with open(path, "rb") as f:
        return f.read()


def check_snippets(mutants):
    ids = [m[0] for m in MUTANTS]
    problems = [f"{i} is listed twice" for i in sorted(set(ids)) if ids.count(i) > 1]
    for mid, fname, old, new, _ in mutants:
        path = os.path.join(SOURCES, fname)
        if not os.path.exists(path):
            problems.append(f"{mid}: {fname} doesn't exist"); continue
        n = read(path).decode().count(old)
        if n != 1:
            problems.append(f"{mid}: the snippet occurs {n} times in {fname} (must be once)")
        if old == new:
            problems.append(f"{mid}: the broken version is the same as the snippet")
    return problems


def git_clean(paths):
    out = subprocess.run(["git", "-C", REPO, "status", "--porcelain", "--", *paths], capture_output=True, text=True)
    return out.returncode == 0 and not out.stdout.strip()


current = {"path": None, "orig": None}


def restore():
    if current["path"]:
        with open(current["path"], "wb") as f:
            f.write(current["orig"])
        current["path"] = None


def on_signal(signum, frame):
    restore()
    sys.exit(130)


def main():
    opts = parse_args(sys.argv[1:])
    unknown = [i for i in opts["ids"] if i not in {m[0] for m in MUTANTS}]
    if unknown:
        sys.exit(f"Unknown mutant IDs: {', '.join(unknown)}")
    chosen = [m for m in MUTANTS if not opts["ids"] or m[0] in opts["ids"]]
    if opts["list"]:
        for mid, fname, _, _, why in chosen:
            print(f"{mid}\t{fname}\t{why}")
        return 0
    problems = check_snippets(chosen)
    if problems:
        print("\n".join(problems))
        return 2
    if opts["check"]:
        print(f"All {len(chosen)} mutants' snippets match exactly once.")
        return 0
    if not git_clean(["Sources", "Tests"]):
        print("Sources/ or Tests/ has uncommitted changes; commit or stash them first.")
        return 3

    atexit.register(restore)
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    out = opts["out"] or tempfile.mkdtemp(prefix="plinth-mutation-probe-")
    os.makedirs(out, exist_ok=True)
    print(f"Logs: {out}", flush=True)
    results = []
    for mid, fname, old, new, why in chosen:
        path = os.path.join(SOURCES, fname)
        orig = read(path)
        current.update(path=path, orig=orig)
        with open(path, "wb") as f:
            f.write(orig.decode().replace(old, new, 1).encode())
        log = os.path.join(out, f"{mid}.log")
        env = dict(os.environ, TMPDIR=tempfile.mkdtemp(prefix=f"plinth-{mid}-") + "/")
        started = time.time()
        with open(log, "w") as lf:
            proc = subprocess.Popen(["swift", "test", "-j", opts["jobs"]], cwd=REPO, stdout=lf, stderr=subprocess.STDOUT,
                                    env=env, start_new_session=True)
            try:
                code = proc.wait(timeout=1800)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                code = None
        restore()
        if subprocess.run(["git", "-C", REPO, "diff", "--quiet", "--", path]).returncode != 0:
            print(f"{path} wasn't restored; stopping. Check it with git diff.")
            return 4
        text = open(log, errors="replace").read()
        failed = sorted({f"{c}.{t}" for c, t in FAIL_RE.findall(text)} | set(SWIFT_TESTING_FAIL_RE.findall(text)))
        if code is None:
            verdict = "TIMEOUT"
        elif code == 0:
            verdict = "SURVIVED"
        elif STARTED not in text:
            verdict = "UNVIABLE"
        else:
            verdict = "KILLED"
        seconds = int(time.time() - started)
        results.append((mid, verdict))
        shown = "; ".join(failed[:4]) + (f" (+{len(failed) - 4} more)" if len(failed) > 4 else "")
        print(f"{mid}\t{verdict}\t{seconds}s\t{why}\t{shown}", flush=True)

    counts = {v: sum(1 for _, r in results if r == v) for v in ("KILLED", "SURVIVED", "UNVIABLE", "TIMEOUT")}
    print(" ".join(f"{k.lower()} {n}" for k, n in counts.items() if n) + f" of {len(results)}")
    return 0 if counts["KILLED"] == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
