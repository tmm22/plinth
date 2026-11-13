#!/usr/bin/env python3
"""Plinth's mutation probe: does the test suite notice when a safety rule breaks?

Each mutant plants one deliberate bug in Sources/Plinth (an exact snippet that must occur exactly once, replaced
by a broken version), runs the full `swift test`, records whether any test failed, and puts the file back.
Every mutant must be KILLED (at least one test fails). A SURVIVED mutant is a safety rule, or the call that wires
it into a flow, that no test protects. An UNVIABLE mutant didn't compile, so it proves nothing; a mutant whose
snippet no longer matches stops the probe before anything is changed. When code moves, update the snippet to the
equivalent code; never drop a mutant without a replacement.

Verdicts, one line per mutant (the log of every run is kept in the logs folder):
  KILLED          at least one test failed; the failing tests are named. The rule is protected.
  KILLED (crash)  the tests started and the run failed, but no failing test could be named (a crash or fatal
                  error). It still counts as killed; read its log to see what stopped the run.
  SURVIVED        every test passed with the bug in place: no test protects that rule. Add one.
  UNVIABLE        the tests never started (usually the mutant doesn't compile), so it proves nothing. Fix the
                  broken version so it compiles.
  TIMEOUT         no result within the time limit (--timeout, 30 minutes by default). Its test processes are
                  stopped and the file is put back.

Baseline: before the first mutant, the unmutated suite runs once. If it fails (or never starts its tests), the
probe stops with exit 5, because a test that already fails, or fails now and then, would make every mutant look
killed. Pass --no-baseline only straight after a green full `swift test` of this same checkout (for example the
previous batch's baseline).

Time: a full run is 61 or more mutants at 1.5-3 minutes each, roughly 1.5-3 hours, plus the baseline. Run it in
batches of IDs that fit your time limit: an agent's background command stops after 2 hours, so about 30 IDs per
batch leaves room even at 3 minutes each. --list prints the IDs.

It edits the checkout in place (SwiftPM's build folder isn't relocatable, and a cold build takes ~20 minutes): it
refuses to start unless Sources/ and Tests/ are clean, and only one probe runs in a checkout at a time (a lock on
.git/plinth-mutation-probe-lock). Each mutant and each restore is written whole (a temporary file and a rename) with
Ctrl-C and the other stop signals held back, and before a mutant is planted the probe records a marker in the git
folder (.git/plinth-mutation-probe: the file's path and a byte copy of the original), removed once the file is back
and checked. Ctrl-C, SIGTERM, SIGHUP (the terminal closed) and SIGQUIT stop `swift test` and its test runner (xctest
runs in its own process group), put the file back and exit 128 + the signal number (a signal already ignored at
launch, as under nohup, stays ignored). A hard kill (SIGKILL, a crash, the Mac stopping) can't clean up: the marker
stays, scripts/build-app.sh refuses to build while it exists, and the next run of the probe, or --restore on its
own, puts the file back first. A `swift test` orphaned by a hard kill finishes by itself. Don't edit files or build
in this checkout while the probe runs.

--jobs (default 3) is passed to `swift test -j`. The owner's Mac has 8 GB of memory: more parallel compile jobs
run out of memory and swap, which is slower overall and can push a batch past its time limit.

--out names the logs folder (default: a new temporary folder). It must be outside the checkout: the logs hold
local paths and must never be committed. Each run gets its own TMPDIR, removed afterwards.

Usage: python3 -I scripts/mutation-probe.py [--check | --list | --restore] [--no-baseline] [--jobs N]
           [--out DIR] [--timeout SECONDS] [IDS...]
  --check    only check that every snippet matches exactly once (changes nothing)
  --list     list the mutant IDs, files and what each bug means
  --restore  only put back a file left planted by a probe that was killed hard, and remove its marker
Exit: 0 every mutant killed (or --check, --list or --restore succeeded)
      1 some mutants survived, were unviable or timed out
      2 a usage error (an unknown ID or option, a missing or bad value, --out inside the checkout) or a snippet
        that doesn't match exactly once
      3 Sources/ or Tests/ not clean, not a git checkout, or another probe is running in this checkout
      4 a file couldn't be put back, or the marker couldn't be written or removed (the marker then stays)
      5 the unmutated baseline run failed or never started its tests
      128 + N  stopped by signal N after cleaning up (130 Ctrl-C, 143 SIGTERM, 129 SIGHUP, 131 SIGQUIT); 4 instead
               if the file couldn't be put back
"""
import atexit, fcntl, hashlib, os, re, shutil, signal, stat, subprocess, sys, tempfile, time

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
    ("W06", "BatchPay.swift",
     '        return BatchPayReviewedDraft(id: id, order: order, exclusion: alreadyPaid ?? reason)',
     '        _ = reason\n        return BatchPayReviewedDraft(id: id, order: order, exclusion: alreadyPaid)',
     "Pay Several Drafts: exclusion reasons are worked out but not applied"),
    ("W06b", "BatchPay.swift",
     '        guard draft.payable, let reason = duplicates[draft.id] else { return draft }',
     '        guard draft.payable, let reason = duplicates[draft.id], draft.id.isEmpty else { return draft }',
     "Pay Several Drafts: marketplace duplicates are not left out"),
    ("W06c", "BatchPay.swift",
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
    # Lifting the lock, recording it in the batch, the draft-create outcome, and Pay Several Drafts' loop and sheet.
    ("W15", "SlantOrderWrite.swift",
     '        if orderMutationErrorProvesNoEffect(error, method: method) {',
     '        if orderMutationErrorProvesNoEffect(error, method: method) || !orderID.isEmpty {',
     "Single pay/cancel review: any failed write lifts the lock, even a timeout or 5xx"),
    ("W16", "SlantOrderWrite.swift",
     '        if batchPayAcceptedOutcomeStaysLocked(record.completedOrder) {',
     '        if batchPayAcceptedOutcomeStaysLocked(record.completedOrder) && orderID.isEmpty {',
     "Single pay review: a 2xx whose order still shows DRAFT lifts the lock"),
    ("W17", "SlantOrderWrite.swift",
     '    if !batchPayAcceptedOutcomeStaysLocked(completed) {',
     '    if !batchPayAcceptedOutcomeStaysLocked(completed) || !id.isEmpty {',
     "Pay Several Drafts: a 2xx whose order still shows DRAFT lifts the lock"),
    ("W18", "SlantOrderWrite.swift",
     '        if case .refused = outcome { env.clearOutcomeUnknown(id) }',
     '        env.clearOutcomeUnknown(id)',
     "Pay Several Drafts: any failed pay lifts the lock, even a timeout or 5xx"),
    ("W19", "SlantOrderWrite.swift",
     '    env.markOutcomeUnknown(id, .pay, latest["status"] as? String)\n',
     '',
     "Pay Several Drafts: the lock is never recorded before a pay"),
    ("W20", "OrderDraftSender.swift",
     '            guard orderCreatedID(order) != nil else { throw StudioError("Slant didn’t return an order number.") }\n',
     '',
     "Create Draft: a reply without an order number counts as created"),
    ("W21", "OrderDraftSender.swift",
     '            environment.noteAttempt(attempt, recipient, date, marker, platformID)\n',
     '',
     "Create Draft: an unclear create isn't remembered, so Create Anyway is never asked"),
    ("W22", "BatchPay.swift",
     '        let write = SlantWritesInFlight.shared.begin(.payDrafts)',
     '        let write = UUID()',
     "Pay Several Drafts: quitting mid-batch doesn't ask first (a source check catches this)"),
    ("W23", "BatchPay.swift",
     '            if case .stop(let reason) = batchPayNextStep(after: result.outcome) {',
     '            if case .stop(let reason) = batchPayNextStep(after: result.outcome), reason.isEmpty {',
     "Pay Several Drafts: the batch keeps paying after a refusal or unclear outcome (a source check catches this)"),
    ("W24", "BatchPay.swift",
     '            guard store.unknownOutcomeOrderIDs.isEmpty else {',
     '            guard store.unknownOutcomeOrderIDs.isEmpty || !draft.id.isEmpty else {',
     "Pay Several Drafts: pays on while another order's outcome is unknown (a source check catches this)"),
    ("W25", "BatchPay.swift",
     '            guard accountUnchanged(store) else {\n                stopMessage = "Stopped because the account or platform changed. The rest weren’t paid."',
     '            guard accountUnchanged(store) || !draft.id.isEmpty else {\n                stopMessage = "Stopped because the account or platform changed. The rest weren’t paid."',
     "Pay Several Drafts: pays on after the key or platform changed (a source check catches this)"),
    ("W26", "BatchPay.swift",
     '        store.busy = true\n        store.progress = "Paying orders"',
     '        store.progress = "Paying orders"',
     "Pay Several Drafts: other Slant tasks can run between its payments (a source check catches this)"),
    ("W27", "SlantOrderWrite.swift",
     '    if record.didWrite {',
     '    if record.attemptedWrite {',
     "Single review sheet: a write whose outcome is unknown is shown as done"),
    ("W28", "OrdersView.swift",
     '                onCompleted(orderID, succeeded.order)\n',
     '',
     "Single review sheet: a confirmed pay or cancel never updates the order list (a source check catches this)"),
]


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO, "Sources", "Plinth")
FAIL_RE = re.compile(r"(?:Test Case '-|error: -)\[PlinthTests\.(\w+) (\w+)\]'?(?: failed| :)")
SWIFT_TESTING_FAIL_RE = re.compile(r"Test (\S+?)\(\) .*failed")
STARTED = "Test Suite 'All tests' started"
USAGE = ("usage: python3 -I scripts/mutation-probe.py [--check | --list | --restore] [--no-baseline] [--jobs N] "
         "[--out DIR] [--timeout SECONDS] [IDS...]")
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT)
DEFAULT_TIMEOUT = 1800  # seconds for one `swift test`
KILL_GRACE = 5  # seconds between SIGTERM and SIGKILL when stopping test processes
# Both live in the git folder, so they are never committed. The marker folder exists exactly while a source file may
# hold a planted mutant (build-app.sh refuses to build while it does); the lock file keeps a second probe out.
MARKER_NAME, LOCK_NAME = "plinth-mutation-probe", "plinth-mutation-probe-lock"
MARKER_PATH, MARKER_COPY, MARKER_PLANTED = "path", "original", "planted.sha256"
TMP_SUFFIX = ".plinth-mutation-probe-tmp"
TEST_RUNNERS = ("xctest", "swiftpm-testing-helper")

# Shared with the signal handler and the clean-up: the running `swift test`, its TMPDIR and the planted file.
state = {"proc": None, "tmpdir": None, "path": None, "orig": None, "marker": None, "stopping": None}


class UsageError(Exception):
    pass


class Interrupted(BaseException):
    """Raised by the signal handler, so the clean-up runs in ordinary code rather than inside the handler."""

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def say(*parts, err=False):
    """print that never raises: after SIGHUP the terminal may be gone, and the clean-up must still finish."""
    try:
        print(*parts, file=sys.stderr if err else sys.stdout, flush=True)
    except (OSError, ValueError):
        pass


def positive_int(name, value):
    if not re.fullmatch(r"[0-9]+", value) or int(value) < 1:
        raise UsageError(f"{name} needs a whole number of 1 or more, not {value!r}")
    return value


def parse_args(argv):
    opts = {"check": False, "list": False, "restore": False, "baseline": True, "help": False,
            "jobs": "3", "out": None, "timeout": DEFAULT_TIMEOUT, "ids": []}
    flags = {"--check": "check", "--list": "list", "--restore": "restore", "-h": "help", "--help": "help"}
    i = 0
    while i < len(argv):
        arg = argv[i]
        i += 1
        name, eq, value = arg.partition("=") if arg.startswith("--") else (arg, "", "")
        if name in ("--jobs", "--out", "--timeout"):
            if not eq:
                if i >= len(argv) or argv[i].startswith("--"):
                    raise UsageError(f"{name} needs a value")
                value = argv[i]
                i += 1
            if not value:
                raise UsageError(f"{name} needs a value")
            if name == "--jobs":
                opts["jobs"] = positive_int(name, value)
            elif name == "--timeout":
                opts["timeout"] = int(positive_int(name, value))
            else:
                opts["out"] = value
        elif name in flags or name == "--no-baseline":
            if eq:
                raise UsageError(f"{name} takes no value")
            if name == "--no-baseline":
                opts["baseline"] = False
            else:
                opts[flags[name]] = True
        elif arg.startswith("-"):
            raise UsageError(f"unknown option {arg}")
        else:
            opts["ids"].append(arg)
    if opts["restore"] and (opts["check"] or opts["list"] or opts["ids"]):
        raise UsageError("--restore takes no mutant IDs and can't be combined with --check or --list")
    return opts


def inside_repo(path):
    for repo, here in ((os.path.abspath(REPO), os.path.abspath(path)),
                       (os.path.realpath(REPO), os.path.realpath(path))):
        if here == repo or here.startswith(repo.rstrip(os.sep) + os.sep):
            return True
    return False


def read(path):
    with open(path, "rb") as f:
        return f.read()


def check_snippets(mutants, originals=None):
    """`originals` maps a path to the bytes to check instead of the file (the copy kept by a running probe)."""
    originals = originals or {}
    ids = [m[0] for m in MUTANTS]
    problems = [f"{i} is listed twice" for i in sorted(set(ids)) if ids.count(i) > 1]
    for mid, fname, old, new, _ in mutants:
        path = os.path.join(SOURCES, fname)
        if path not in originals and not os.path.exists(path):
            problems.append(f"{mid}: {fname} doesn't exist"); continue
        n = (originals[path] if path in originals else read(path)).decode().count(old)
        if n != 1:
            problems.append(f"{mid}: the snippet occurs {n} times in {fname} (must be once)")
        if old == new:
            problems.append(f"{mid}: the broken version is the same as the snippet")
    return problems


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True)


def git_path(name):
    """`name` inside this checkout's git folder, or None outside a git checkout."""
    try:
        out = git("rev-parse", "--git-path", name)
    except OSError:
        return None
    path = out.stdout.decode(errors="replace").rstrip("\n")
    if out.returncode != 0 or not path:
        return None
    return path if os.path.isabs(path) else os.path.join(REPO, path)


def git_clean(paths):
    try:
        out = subprocess.run(["git", "-C", REPO, "status", "--porcelain", "--", *paths], capture_output=True, text=True)
    except OSError:
        return False
    return out.returncode == 0 and not out.stdout.strip()


def take_run_lock():
    """(file descriptor, None) once this probe holds the checkout's lock, or (None, holder's pid) when another does.
    The lock goes with the process, however it ends; the descriptor isn't inherited by `swift test`."""
    path = git_path(LOCK_NAME)
    if path is None:
        raise OSError("git no longer finds the git folder")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        holder = os.read(fd, 32).decode(errors="replace").strip()
        os.close(fd)
        return None, holder
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode())
    return fd, None


class blocked:
    """Holds SIGINT, SIGTERM, SIGHUP and SIGQUIT back until the block ends, so a write and its marker change can't
    be split by a stop. (SIGKILL can't be held back; the marker covers that.)"""

    def __enter__(self):
        self.old = signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)

    def __exit__(self, *exc):
        signal.pthread_sigmask(signal.SIG_SETMASK, self.old)
        return False


def unblock_signals():
    # Runs in the child before exec: a blocked signal mask is inherited, and `swift test` must be stoppable.
    signal.pthread_sigmask(signal.SIG_UNBLOCK, SIGNALS)


def tmp_name(path):
    """The one temporary name the probe writes beside `path` (so a hard kill's leftover is known to be its own)."""
    return os.path.join(os.path.dirname(path), "." + os.path.basename(path) + TMP_SUFFIX)


def write_new(path, data):
    """Creates `path` (never replacing an existing file) and flushes it to disk."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


def write_atomically(path, data):
    """Replaces `path` whole: a temporary file in the same folder, then os.replace, keeping the file's mode."""
    tmp = tmp_name(path)
    mode = stat.S_IMODE(os.stat(path).st_mode)
    write_new(tmp, data)
    try:
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def remove_marker(marker):
    """Removes the marker's own files, the path record first (a marker without it means nothing is planted), then
    the folder. Anything else in the folder is left alone, and then the folder stays too."""
    for name in (MARKER_PATH, MARKER_PATH + ".tmp", MARKER_PLANTED, MARKER_COPY):
        try:
            os.unlink(os.path.join(marker, name))
        except FileNotFoundError:
            pass
    os.rmdir(marker)


def plant(path, orig, mutated):
    """Records the marker (a copy of the original, the mutant's hash, then the path record), then writes the mutant."""
    marker = state["marker"]
    with blocked():
        os.mkdir(marker)
        try:
            write_new(os.path.join(marker, MARKER_COPY), orig)
            write_new(os.path.join(marker, MARKER_PLANTED), hashlib.sha256(mutated).hexdigest().encode() + b"\n")
            write_new(os.path.join(marker, MARKER_PATH + ".tmp"), os.path.relpath(path, REPO).encode() + b"\n")
            os.replace(os.path.join(marker, MARKER_PATH + ".tmp"), os.path.join(marker, MARKER_PATH))
        except BaseException:
            try:
                remove_marker(marker)
            except OSError:
                pass
            raise
        # From here the file may hold the mutant, so the clean-up puts it back.
        state.update(path=path, orig=orig)
        write_atomically(path, mutated)


def restore():
    """Puts the planted file back, checks its bytes and removes the marker. Returns None, or what went wrong. It is
    tried once: after a failure the marker stays, so --restore, the next run and build-app.sh notice."""
    path, orig, marker = state["path"], state["orig"], state["marker"]
    if path is None:
        return None
    rel = os.path.relpath(path, REPO)
    with blocked():
        state["path"] = state["orig"] = None
        try:
            write_atomically(path, orig)
            if read(path) != orig:
                raise OSError("its contents read back differ")
        except OSError as error:
            return (f"Couldn't put {rel} back ({error}). Its original is kept in {marker}; once the problem is fixed, "
                    "run python3 -I scripts/mutation-probe.py --restore.")
        try:
            remove_marker(marker)
        except OSError as error:
            return f"Put {rel} back, but couldn't remove the marker {marker} ({error}); check it and remove it by hand."
    return None


def signal_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
    except (ProcessLookupError, PermissionError):
        pass


def ps_field(pid, field):
    try:
        out = subprocess.run(["ps", "-o", f"{field}=", "-p", str(pid)], capture_output=True, text=True)
    except OSError:
        return ""
    return out.stdout.strip()


def stray_test_runners():
    """Test runners (xctest, or swiftpm-testing-helper for Swift Testing) whose command line holds this checkout's
    .build path. They run in their own process group, so stopping `swift test`'s group can leave them running."""
    dirs = sorted({os.path.join(p, ".build") + os.sep for p in (os.path.abspath(REPO), os.path.realpath(REPO))})
    pids = set()
    for d in dirs:
        try:
            out = subprocess.run(["pgrep", "-f", re.sub(r"([\\.\[\](){}*+?|^$])", r"\\\1", d)],
                                 capture_output=True, text=True)
        except OSError:
            continue
        pids.update(int(word) for word in out.stdout.split() if word.isdigit())
    pids.discard(os.getpid())
    return [pid for pid in sorted(pids) if os.path.basename(ps_field(pid, "comm")) in TEST_RUNNERS
            and any(d in ps_field(pid, "args") for d in dirs)]


def stop_strays():
    pids = stray_test_runners()
    if not pids:
        return
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + KILL_GRACE
    while time.time() < deadline:
        if not stray_test_runners():
            return
        time.sleep(0.2)
    for pid in stray_test_runners():  # looked up again, so a PID reused meanwhile is never signalled
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def stop_child():
    """Stops the running `swift test`: SIGTERM to its process group, a short wait, then SIGKILL, and waits for it;
    then its test runner."""
    proc = state["proc"]
    if proc is None:
        return
    signal_group(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=KILL_GRACE)
    except subprocess.TimeoutExpired:
        pass
    signal_group(proc.pid, signal.SIGKILL)  # whatever is left of the group
    proc.wait()
    state["proc"] = None
    stop_strays()


def remove_tmpdir():
    if state["tmpdir"]:
        shutil.rmtree(state["tmpdir"], ignore_errors=True)
        state["tmpdir"] = None


def cleanup():
    """Stops the tests, removes their TMPDIR, then puts the planted file back. Safe to call more than once; returns
    what went wrong putting the file back, or None."""
    with blocked():
        stop_child()
        remove_tmpdir()
        problem = restore()
    if problem:
        say(problem, err=True)
    return problem


def on_signal(signum, frame):
    if state["stopping"]:
        return  # already stopping: let the clean-up finish
    state["stopping"] = signum
    raise Interrupted(signum)


def run_suite(name, jobs, timeout, out):
    """One full `swift test` with its own TMPDIR. Returns (exit code, or None after a timeout; log; seconds)."""
    log = os.path.join(out, f"{name}.log")
    started = time.time()
    with blocked():
        state["tmpdir"] = tempfile.mkdtemp(prefix=f"plinth-{name}-")
    env = dict(os.environ, TMPDIR=state["tmpdir"] + "/")
    with open(log, "w") as lf:
        try:
            with blocked():
                state["proc"] = subprocess.Popen(["swift", "test", "-j", jobs], cwd=REPO, stdin=subprocess.DEVNULL,
                                                 stdout=lf, stderr=subprocess.STDOUT, env=env,
                                                 start_new_session=True, preexec_fn=unblock_signals)
        except OSError as error:
            lf.write(f"Couldn't start swift test: {error}\n")
            code = 127
        else:
            try:
                code = state["proc"].wait(timeout=timeout)
                state["proc"] = None
            except subprocess.TimeoutExpired:
                stop_child()
                code = None
    if code is None:
        with open(log, "a") as lf:
            lf.write(f"\n[mutation-probe] No result within {timeout} s; the test processes were stopped.\n")
    remove_tmpdir()
    with open(log, errors="replace") as lf:
        text = lf.read()
    return code, text, int(time.time() - started), log


def failed_tests(text):
    return sorted({f"{c}.{t}" for c, t in FAIL_RE.findall(text)} | set(SWIFT_TESTING_FAIL_RE.findall(text)))


def shown(names):
    return "; ".join(names[:4]) + (f" (+{len(names) - 4} more)" if len(names) > 4 else "")


def recover(marker):
    """Puts back a file left planted by a probe that was killed hard. None when there's no marker, 0 once it's dealt
    with, 4 when it couldn't be (the marker then stays)."""
    if not os.path.lexists(marker):
        return None
    if os.path.islink(marker) or not os.path.isdir(marker):
        say(f"{marker} exists but isn't a folder the probe made; it was left alone. Check it and remove it by hand.")
        return 4
    if not os.path.exists(os.path.join(marker, MARKER_PATH)):
        try:
            with blocked():
                remove_marker(marker)
        except OSError as error:
            say(f"Found an incomplete marker {marker} (a probe was killed before planting anything, so no source file "
                f"was changed) but couldn't remove it ({error}). Check it and remove it by hand.")
            return 4
        say("A probe was killed hard before it planted a mutant: removed its incomplete marker. No source file was "
            "changed.")
        return 0
    copy = os.path.join(marker, MARKER_COPY)
    try:
        rel = read(os.path.join(marker, MARKER_PATH)).decode().rstrip("\n")
        orig = read(copy)
        planted = read(os.path.join(marker, MARKER_PLANTED)).decode().strip()
    except (OSError, UnicodeDecodeError) as error:
        say(f"The marker {marker} can't be read ({error}); it was left alone. Check the files it names and remove it.")
        return 4
    if os.path.isabs(rel) or os.path.normpath(rel) != rel or not rel.startswith("Sources" + os.sep):
        say(f"The marker {marker} names {rel!r}, which isn't a file under Sources/; it was left alone.")
        return 4
    path = os.path.join(REPO, rel)
    say(f"A previous probe was killed hard (or the Mac stopped) before it could put {rel} back.")
    try:
        current = read(path) if os.path.exists(path) else None
        with blocked():
            if os.path.exists(tmp_name(path)):
                os.unlink(tmp_name(path))  # the probe's own half-written file
            if current == orig:
                done = f"{rel} already holds its original contents."
            elif current is not None and hashlib.sha256(current).hexdigest() == planted:
                write_atomically(path, orig)
                if read(path) != orig:
                    raise OSError("the contents read back differ")
                done = f"Put {rel} back from the copy the probe kept."
            else:
                say(f"{rel} {'is missing' if current is None else 'holds neither its original nor the planted mutant'} "
                    f"(it changed after the probe stopped), so the probe didn't touch it. Its original is kept at "
                    f"{copy}: compare them, then remove {marker}.")
                return 4
    except OSError as error:
        say(f"Couldn't put {rel} back ({error}). Its original is kept at {copy}.")
        return 4
    head, now = git("rev-parse", "-q", "--verify", f"HEAD:{rel}"), git("hash-object", "--", rel)
    if head.returncode == 0 and now.returncode == 0 and head.stdout.strip() == now.stdout.strip():
        if git("diff", "--quiet", "--", rel).returncode == 0:
            checked = "git diff confirms it matches the last commit."
        else:
            checked = "It matches the last commit, but git diff still shows a staged change; check git diff --cached."
    else:
        checked = ("The last commit's version differs (the checkout changed since that run started), so git can't "
                   "confirm it; check it with git diff.")
    try:
        with blocked():
            remove_marker(marker)
    except OSError as error:
        say(f"{done} {checked} But the marker {marker} couldn't be removed ({error}); check it and remove it by hand.")
        return 4
    say(f"{done} {checked} Removed the marker.")
    return 0


def run(opts, chosen):
    state["marker"] = marker = git_path(MARKER_NAME)
    recovered = recover(marker)
    if recovered == 4:
        return 4
    if opts["restore"]:
        if recovered is None:
            say("Nothing to restore: no mutant is planted in this checkout.")
        return 0
    problems = check_snippets(chosen)
    if problems:
        say("\n".join(problems))
        return 2
    if not git_clean(["Sources", "Tests"]):
        say("Sources/ or Tests/ has uncommitted changes; commit or stash them first.")
        return 3
    if opts["out"] is None and inside_repo(tempfile.gettempdir()):
        say(f"mutation-probe: TMPDIR ({tempfile.gettempdir()}) is inside the checkout, and logs hold local paths that "
            "must never be committed. Choose a logs folder outside it with --out.", err=True)
        return 2
    out = opts["out"] or tempfile.mkdtemp(prefix="plinth-mutation-probe-")
    os.makedirs(out, exist_ok=True)
    say(f"Logs: {out}")
    jobs, timeout = opts["jobs"], opts["timeout"]
    if opts["baseline"]:
        code, text, seconds, log = run_suite("baseline", jobs, timeout, out)
        if code != 0 or STARTED not in text:
            why = (f"gave no result within {timeout} s" if code is None
                   else "never started its tests (did it build?)" if STARTED not in text else f"failed (exit {code})")
            say(f"baseline\tFAILED\t{seconds}s\tthe unmutated suite {why}\t{shown(failed_tests(text))}")
            say("The unmutated suite must pass before any mutant: with a failing or flaky test every mutant would look "
                f"killed. Fix it or run it again; nothing was changed. Log: {log}")
            return 5
        say(f"baseline\tPASSED\t{seconds}s\tthe unmutated suite")
    results = []
    for mid, fname, old, new, why in chosen:
        path = os.path.join(SOURCES, fname)
        orig = read(path)
        try:
            plant(path, orig, orig.decode().replace(old, new, 1).encode())
        except OSError as error:
            problem = cleanup()
            say(f"Couldn't plant {mid} ({error})" + ("." if problem else "; nothing is left planted."))
            return 4
        code, text, seconds, _ = run_suite(mid, jobs, timeout, out)
        problem = restore()
        if problem:
            say(problem)
            return 4
        if git("diff", "--quiet", "--", path).returncode != 0:
            say(f"{path} holds its original bytes again, but git diff still shows a change (was it edited or "
                "committed during the run?); stopping. Check it with git diff.")
            return 4
        failed = failed_tests(text)
        if code is None:
            verdict = "TIMEOUT"
        elif code == 0:
            verdict = "SURVIVED"
        elif STARTED not in text:
            verdict = "UNVIABLE"
        else:
            verdict = "KILLED"
        label = "KILLED (crash)" if verdict == "KILLED" and not failed else verdict
        results.append((mid, verdict, failed))
        say(f"{mid}\t{label}\t{seconds}s\t{why}\t{shown(failed)}")

    counts = {v: sum(1 for _, r, _ in results if r == v) for v in ("KILLED", "SURVIVED", "UNVIABLE", "TIMEOUT")}
    crashes = sum(1 for _, r, failed in results if r == "KILLED" and not failed)
    say(" ".join(f"{k.lower()} {n}" + (f" ({crashes} crash)" if k == "KILLED" and crashes else "")
                 for k, n in counts.items() if n) + f" of {len(results)}")
    missed = [f"{mid} ({r})" for mid, r, _ in results if r != "KILLED"]
    if missed:
        say("Not killed: " + ", ".join(missed))
    return 0 if counts["KILLED"] == len(results) else 1


def main(argv):
    try:
        opts = parse_args(argv)
        known = {m[0] for m in MUTANTS}
        unknown = [i for i in opts["ids"] if i not in known]
        if unknown:
            raise UsageError(f"unknown mutant ID{'s' if len(unknown) > 1 else ''} {', '.join(unknown)} "
                             "(--list shows them)")
        if opts["out"] is not None and inside_repo(opts["out"]):
            raise UsageError(f"--out {opts['out']} is inside the checkout; logs hold local paths and must never be "
                             "committed, so choose a folder outside it")
    except UsageError as error:
        say(f"mutation-probe: {error}", err=True)
        say(USAGE, err=True)
        return 2
    if opts["help"]:
        say(__doc__.strip())
        return 0
    chosen = [m for m in MUTANTS if not opts["ids"] or m[0] in opts["ids"]]
    if opts["list"]:
        for mid, fname, _, _, why in chosen:
            say(f"{mid}\t{fname}\t{why}")
        return 0
    if opts["check"]:
        # Read-only, and safe while a probe runs: a planted file is checked through the copy the probe kept.
        marker, originals = git_path(MARKER_NAME), {}
        if marker and os.path.lexists(marker):
            try:
                rel = read(os.path.join(marker, MARKER_PATH)).decode().rstrip("\n")
                originals[os.path.join(REPO, rel)] = read(os.path.join(marker, MARKER_COPY))
                say(f"Note: a mutant is planted in {rel} (a probe is running, or one was killed hard: then run "
                    "--restore); its snippets were checked against the copy the probe kept.")
            except (OSError, UnicodeDecodeError):
                say(f"Note: {marker} exists but is incomplete; nothing is planted (--restore removes it).")
        problems = check_snippets(chosen, originals)
        if problems:
            say("\n".join(problems))
            return 2
        say(f"All {len(chosen)} mutants' snippets match exactly once.")
        return 0

    for signum in SIGNALS:
        if signal.getsignal(signum) != signal.SIG_IGN:  # a signal ignored at launch (nohup) stays ignored
            signal.signal(signum, on_signal)
    atexit.register(cleanup)
    try:
        if git_path(MARKER_NAME) is None:
            say("The probe needs a git checkout (it checks git status and keeps its marker in the git folder).")
            return 3
        try:
            lock, holder = take_run_lock()
        except OSError as error:
            say(f"Couldn't create the probe's lock file in the git folder ({error}), so it can't keep a marker there "
                "either.")
            return 4
        if lock is None:
            say(f"Another mutation probe{f' (pid {holder})' if holder else ''} is running in this checkout; "
                "wait for it to finish.")
            return 3
        return run(opts, chosen)
    except Interrupted as stop:
        problem = cleanup()
        name = signal.Signals(stop.signum).name
        say(f"Stopped by {name}: the tests were stopped" + (" but the file couldn't be put back." if problem
                                                             else " and nothing is left planted."), err=True)
        return 4 if problem else 128 + stop.signum
    finally:
        cleanup()


if __name__ == "__main__":
    try:
        code = main(sys.argv[1:])
    except Interrupted as late:  # a stop that arrived after main's own handling
        code = 4 if cleanup() else 128 + late.signum
    state["stopping"] = state["stopping"] or "exiting"  # nothing is planted now; ignore stops while exiting
    sys.exit(code)
