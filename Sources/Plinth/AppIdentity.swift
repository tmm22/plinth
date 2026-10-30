import Foundation

/// The packaged app's bundle identifier (scripts/build-app.sh `CFBundleIdentifier`).
let appBundleIdentifier = "io.github.tmm22.plinth"

/// The bundle identifier the app had as Slant Studio. A copy of the old app may still be installed and running.
let legacyAppBundleIdentifier = "app.slantstudio.mac"

/// Every bundle identifier a copy of this app may run under, the current one first.
let appBundleIdentifiersIncludingLegacy = [appBundleIdentifier, legacyAppBundleIdentifier]
