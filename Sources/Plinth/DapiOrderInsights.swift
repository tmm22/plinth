import Foundation

// Read-only tools over loaded 3DAPI orders: Needs Attention, Export Orders, the Spending Report, Tracking for Your
// Shop, the Profit check total and Report a Problem. PLACEHOLDER for the shared interface: the insights implementer
// replaces the bodies (keeping these names and signatures) and adds the rest.

/// Why this order needs the seller's attention now, or nil. Read-only, display only.
func dapiOrderAttention(_ order: DapiOrder, now: Date = Date()) -> String? {
    nil
}
