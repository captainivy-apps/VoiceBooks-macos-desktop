import Foundation

struct TtsLanguageGroup: Hashable {
    let id: String
    let label: String
    let sortOrder: Int
}

enum TtsLanguageGroups {
    static let allLabel = "全部语言"

    private static let groupsByLanguage: [String: TtsLanguageGroup] = [
        "zh": TtsLanguageGroup(id: "zh", label: "中文", sortOrder: 1),
        "zh+en": TtsLanguageGroup(id: "zh_en", label: "中英双语", sortOrder: 2),
        "yue": TtsLanguageGroup(id: "yue", label: "粤语", sortOrder: 3),
        "en": TtsLanguageGroup(id: "en", label: "英文", sortOrder: 4),
        "de": TtsLanguageGroup(id: "de", label: "德语", sortOrder: 10),
        "fr": TtsLanguageGroup(id: "fr", label: "法语", sortOrder: 11),
        "es": TtsLanguageGroup(id: "es", label: "西班牙语", sortOrder: 12),
        "pt": TtsLanguageGroup(id: "pt", label: "葡萄牙语", sortOrder: 13),
        "ru": TtsLanguageGroup(id: "ru", label: "俄语", sortOrder: 14),
        "ko": TtsLanguageGroup(id: "ko", label: "韩语", sortOrder: 15),
        "vi": TtsLanguageGroup(id: "vi", label: "越南语", sortOrder: 16),
        "th": TtsLanguageGroup(id: "th", label: "泰语", sortOrder: 17),
        "tr": TtsLanguageGroup(id: "tr", label: "土耳其语", sortOrder: 18),
        "fa": TtsLanguageGroup(id: "fa", label: "波斯语", sortOrder: 19),
        "bn": TtsLanguageGroup(id: "bn", label: "孟加拉语", sortOrder: 20),
    ]

    private static let otherGroup = TtsLanguageGroup(id: "other", label: "其他", sortOrder: 99)

    static func groupFor(_ language: String) -> TtsLanguageGroup {
        groupsByLanguage[language.lowercased()] ?? otherGroup
    }

    static func groupModels(_ models: [TtsModelEntity]) -> [(group: TtsLanguageGroup, models: [TtsModelEntity])] {
        Dictionary(grouping: models) { groupFor($0.language) }
            .map { (group: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.group.sortOrder < $1.group.sortOrder }
    }

    static func distinctGroups(_ models: [TtsModelEntity]) -> [TtsLanguageGroup] {
        var seen = Set<String>()
        var result: [TtsLanguageGroup] = []
        for model in models {
            let group = groupFor(model.language)
            if seen.insert(group.id).inserted { result.append(group) }
        }
        return result.sorted { $0.sortOrder < $1.sortOrder }
    }
}
