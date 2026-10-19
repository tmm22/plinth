import Foundation

/// Broad material-family guidance, not provider-specific performance ratings.
enum MaterialGoal: String, CaseIterable, Identifiable, Codable, Sendable {
    case keepCurrent = "Keep my material"
    case rigid = "Rigid indoor part"
    case impact = "Toughness and occasional flex"
    case repeatedFlex = "Repeated flexing"
    case warm = "Warm environment"
    var id: String { rawValue }
    var profile: String? {
        switch self {
        case .rigid: return "PLA"
        case .impact: return "PETG"
        case .keepCurrent, .repeatedFlex, .warm: return nil
        }
    }
    var guidance: String {
        switch self {
        case .keepCurrent: return "Uses your current material selection."
        case .rigid: return "PLA is a starting point for stiff indoor parts used at room temperature."
        case .impact: return "PETG is a starting point for tougher parts with some give. Test the finished part for its intended load."
        case .repeatedFlex: return "For repeated flexing, choose using the supplier’s fatigue data and test the intended movement. The catalogue does not provide enough performance data to select automatically."
        case .warm: return "Match the supplier’s temperature and sustained-load ratings to the intended environment. The catalogue does not provide enough performance data to select automatically."
        }
    }
}

func recommendedMaterials(for goal: MaterialGoal, in materials: [Record]) -> [Record] {
    guard let profile = goal.profile else { return [] }
    var seen = Set<String>()
    return materials.filter {
        filamentType($0) == profile && filamentAvailability($0) == true && !$0.id.isEmpty && seen.insert($0.id).inserted
    }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
}
