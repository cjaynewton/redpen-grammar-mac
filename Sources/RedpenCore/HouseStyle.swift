import Foundation

/// Optional writing rules on top of grammar: a personal or team style guide. Everything is off by default.
/// Turn rules on in Settings, or edit `houseStyle` in config.json. See examples/house-style-example.json.
public struct HouseStyle: Codable, Sendable, Equatable {
    /// Flag em dashes, spaced en dashes and "--", and offer a comma or period instead.
    public var noDashes = false
    /// Flag a colon that joins two clauses. Short labels ("Budget: $400K") and lists stay allowed.
    public var colonsOnlyForLabels = false
    /// Words that sound like thinking but say little. Checked in long-form writing only.
    public var containerWords: [String] = []
    /// Phrases to cut, such as "to be clear,".
    public var disclaimers: [String] = []
    /// Flag sentences written in another language (useful with voice typing) and offer an English version.
    public var flagOtherLanguages = false
    /// Hold spelling to one English: "en_CA", "en_US" or "en_GB". Empty accepts all three.
    /// With "en_CA", "color" is flagged and "colour" suggested.
    public var spelling = ""
    /// Extra instructions for Deep check, e.g. "Keep my short sentences."
    public var deepCheckNotes = ""
    /// Style tips switched on, by id ("plain", "ai", "filler" and so on). See `StyleTip`. The name is from 0.8,
    /// when only three word lists existed, so older settings files keep what they had on.
    public var starterSets: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HouseStyle()
        noDashes = try c.decodeIfPresent(Bool.self, forKey: .noDashes) ?? d.noDashes
        colonsOnlyForLabels = try c.decodeIfPresent(Bool.self, forKey: .colonsOnlyForLabels) ?? d.colonsOnlyForLabels
        containerWords = try c.decodeIfPresent([String].self, forKey: .containerWords) ?? d.containerWords
        disclaimers = try c.decodeIfPresent([String].self, forKey: .disclaimers) ?? d.disclaimers
        flagOtherLanguages = try c.decodeIfPresent(Bool.self, forKey: .flagOtherLanguages) ?? d.flagOtherLanguages
        spelling = try c.decodeIfPresent(String.self, forKey: .spelling) ?? d.spelling
        deepCheckNotes = try c.decodeIfPresent(String.self, forKey: .deepCheckNotes) ?? d.deepCheckNotes
        starterSets = StyleTip.migrate(try c.decodeIfPresent([String].self, forKey: .starterSets) ?? d.starterSets)
    }

    /// The example style that ships in examples/: every rule on.
    public static let example: HouseStyle = {
        var s = HouseStyle()
        s.noDashes = true
        s.colonsOnlyForLabels = true
        s.containerWords = ["artifact", "landscape", "framework", "paradigm", "ecosystem", "leverage", "leverages",
                            "leveraging", "trajectory", "delve", "delves", "tapestry", "synergy", "holistic", "robust",
                            "seamless", "seamlessly"]
        s.disclaimers = ["nobody is lying here", "this is not a conspiracy", "to be clear,"]
        s.flagOtherLanguages = true
        s.spelling = "en_CA"
        return s
    }()

    public var isEmpty: Bool {
        !noDashes && !colonsOnlyForLabels && containerWords.isEmpty && disclaimers.isEmpty && !flagOtherLanguages && spelling.isEmpty && starterSets.isEmpty
    }
}
