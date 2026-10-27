import Foundation

/// Broad material-family guidance, not provider-specific performance ratings. The raw values are saved with a part's
/// purpose (`PartIntent.materialGoal`), so they never change; `label` is what the seller sees.
enum MaterialGoal: String, CaseIterable, Identifiable, Codable, Sendable {
    case keepCurrent = "Keep my material"
    case rigid = "Rigid indoor part"
    case impact = "Toughness and occasional flex"
    case repeatedFlex = "Repeated flexing"
    case warm = "Warm environment"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .warm: return "Outdoors, sun or warmth"
        default: return rawValue
        }
    }
    /// Slant filament profiles to suggest, first choice first. Empty: nothing is suggested.
    var profiles: [String] {
        switch self {
        case .rigid: return ["PLA"]
        case .impact: return ["PETG"]
        case .warm: return ["OPM", "PETG"]
        case .keepCurrent, .repeatedFlex: return []
        }
    }
    var guidance: String {
        switch self {
        case .keepCurrent: return "Uses your current material selection."
        case .rigid: return "PLA is a starting point for stiff indoor parts used at room temperature."
        case .impact: return "PETG is a starting point for tougher parts with some give. Test the finished part for its intended load."
        case .repeatedFlex: return "For repeated flexing, choose using the supplier’s fatigue data and test the intended movement. The catalogue does not provide enough performance data to select automatically."
        case .warm: return "OPM is a starting point for parts that live outdoors or in the sun: it handles warmth and sun better than PLA. Large flat OPM parts can lift at the corners, as Slant uses no brims. PETG also handles warmth better than PLA, though not on a car dashboard or behind glass."
        }
    }
}

/// In-stock materials (`available` true; missing or false never counts) of `profile`, by name, without repeats.
func recommendedMaterials(profile: String, in materials: [Record]) -> [Record] {
    var seen = Set<String>()
    return materials.filter {
        filamentType($0) == profile && filamentAvailability($0) == true && !$0.id.isEmpty && seen.insert($0.id).inserted
    }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
}

/// In-stock materials for `goal`, in its profile order (first choice first), each profile by name.
func recommendedMaterials(for goal: MaterialGoal, in materials: [Record]) -> [Record] {
    var seen = Set<String>()
    return goal.profiles.flatMap { recommendedMaterials(profile: $0, in: materials) }.filter { seen.insert($0.id).inserted }
}

/// The requirement a purpose suggests when the seller hasn't chosen one: stiff PLA for parts that mostly sit still,
/// PETG's give for parts that are handled, flexed or hooked. A custom part's use is unknown, so nothing is suggested.
func suggestedMaterialGoal(for purpose: PartPurpose) -> MaterialGoal? {
    switch purpose {
    case .decorative, .enclosure: return .rigid
    case .bracket, .clip: return .impact
    case .custom: return nil
    }
}

/// The requirement material advice uses: the seller's own choice, else the purpose's suggestion. Nil when the seller
/// chose Keep my material, or when nothing is suggested.
func materialAdviceGoal(_ intent: PartIntent) -> (goal: MaterialGoal, chosen: Bool)? {
    if let goal = intent.materialGoal { return goal == .keepCurrent ? nil : (goal, true) }
    return suggestedMaterialGoal(for: intent.purpose).map { ($0, false) }
}

struct MaterialPurposeHintOption: Equatable, Sendable {
    let id: String
    let name: String
}

/// The one-line hint beside Print configuration's Material picker. It only offers a Use button; it never changes the
/// material by itself.
struct MaterialPurposeHint: Equatable, Sendable {
    let message: String
    /// The profile the Use button picks from, such as "PETG".
    let profile: String
    /// In-stock materials of `profile`, by name; never empty.
    let options: [MaterialPurposeHintOption]
}

/// The hint for the selected model, or nil. Shown only for an STL with a saved purpose, when the chosen material isn't
/// one of the requirement's profiles and an in-stock material of one is listed. A purpose's own stiff-PLA suggestion
/// (decorative, enclosure) appears only while no material is chosen: any of Slant's materials suits those, so it
/// never second-guesses a choice. Wording stays relative ("a starting point", "more give"); never food contact.
func materialPurposeHint(intent: PartIntent?, isSTL: Bool, selectedFilamentID: String, filaments: [Record]) -> MaterialPurposeHint? {
    guard isSTL, let intent, let advice = materialAdviceGoal(intent) else { return nil }
    let current = selectedFilamentID.isEmpty ? nil : filaments.first { $0.id == selectedFilamentID }
    if let current, advice.goal.profiles.contains(filamentType(current)) { return nil }
    if !advice.chosen, advice.goal == .rigid, !selectedFilamentID.isEmpty { return nil }
    for profile in advice.goal.profiles {
        let options = recommendedMaterials(profile: profile, in: filaments)
        guard !options.isEmpty, let reason = materialHintReason(profile: profile, goal: advice.goal) else { continue }
        let subject = advice.chosen ? materialHintSubject(advice.goal) : materialHintSubject(intent.purpose)
        return MaterialPurposeHint(message: "\(subject), \(profile) is a common starting point: \(reason).", profile: profile,
                                   options: options.map { MaterialPurposeHintOption(id: $0.id, name: filamentPickerLabel($0)) })
    }
    return nil
}

private func materialHintReason(profile: String, goal: MaterialGoal) -> String? {
    switch (profile, goal) {
    case ("PLA", _): return "it is stiffer than PETG"
    case ("PETG", .warm): return "it handles warmth better than PLA, though not on a car dashboard or behind glass"
    case ("PETG", _): return "it has more give than PLA"
    case ("OPM", _): return "it handles warmth and sun better than PLA"
    default: return nil
    }
}

private func materialHintSubject(_ purpose: PartPurpose) -> String {
    switch purpose {
    case .bracket: return "For a bracket"
    case .enclosure: return "For an enclosure"
    case .clip: return "For a clip"
    case .decorative: return "For a decorative piece"
    case .custom: return "For this part"
    }
}

private func materialHintSubject(_ goal: MaterialGoal) -> String {
    switch goal {
    case .rigid: return "For a stiff indoor part"
    case .impact: return "For a part that takes knocks and some flex"
    case .warm: return "For a part that lives outdoors or in the sun"
    case .keepCurrent, .repeatedFlex: return "For this part"
    }
}

/// Under the requirement picker while it shows the purpose's suggestion rather than the seller's choice.
func materialSuggestedCaption(_ purpose: PartPurpose) -> String {
    "Suggested from its purpose (\(purpose.rawValue.lowercased())). Choose another requirement to change it."
}

/// Shown with the material suggestions: none is for parts that touch food.
let materialAdviceFoodNote = "None of these is suggested for parts that touch food."
