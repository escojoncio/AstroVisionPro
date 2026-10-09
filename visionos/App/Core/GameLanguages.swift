// SPDX-License-Identifier: GPL-2.0-or-later
//
// The language the game is played in. A PlayStation game reads the console's language and
// plays in it when it has it (English otherwise); the emulator sets its console to the language
// given in SHADPS4_CONSOLE_LANGUAGE (a language tag, shadps4-arm64-main/src/common/
// console_language.h), as the PC build does (pc-vr/launch.ps1, setting "language").
//
// The list is the PC build's: the languages ASTRO BOT's releases have between them. A copy has
// those of its region (the Asian release, CUSA12307: Japanese, Korean, Chinese and Thai; the
// European one more European languages). Which ones a copy has shows in its files: ASTRO BOT's
// texts are pictures named ..._lang_<code>.jxm in data/multi_platformer/text/gfx.

import Foundation

struct GameLanguage: Identifiable, Hashable {
    /// The language tag the emulator is given.
    let tag: String
    let native: String
    let english: String
    /// The codes ASTRO BOT's files might use for it (..._lang_<code>.jxm).
    let fileCodes: [String]

    var id: String { tag }
}

enum GameLanguages {
    static let all: [GameLanguage] = [
        GameLanguage(tag: "en-US", native: "English (US)", english: "English (US)", fileCodes: ["us", "en"]),
        GameLanguage(tag: "en-GB", native: "English (UK)", english: "English (UK)", fileCodes: ["gb", "uk"]),
        GameLanguage(tag: "es-ES", native: "Español (España)", english: "Spanish (Spain)", fileCodes: ["es", "sp"]),
        GameLanguage(tag: "es-419", native: "Español (Latinoamérica)", english: "Spanish (Latin America)", fileCodes: ["la", "mx", "419", "las"]),
        GameLanguage(tag: "fr-FR", native: "Français", english: "French", fileCodes: ["fr"]),
        GameLanguage(tag: "fr-CA", native: "Français (Canada)", english: "French (Canada)", fileCodes: ["fc", "ca", "frc"]),
        GameLanguage(tag: "de-DE", native: "Deutsch", english: "German", fileCodes: ["de", "ge"]),
        GameLanguage(tag: "it-IT", native: "Italiano", english: "Italian", fileCodes: ["it"]),
        GameLanguage(tag: "nl-NL", native: "Nederlands", english: "Dutch", fileCodes: ["nl", "du"]),
        GameLanguage(tag: "pt-PT", native: "Português (Portugal)", english: "Portuguese (Portugal)", fileCodes: ["pt", "po"]),
        GameLanguage(tag: "pt-BR", native: "Português (Brasil)", english: "Portuguese (Brazil)", fileCodes: ["br", "pb"]),
        GameLanguage(tag: "ru-RU", native: "Русский", english: "Russian", fileCodes: ["ru"]),
        GameLanguage(tag: "pl-PL", native: "Polski", english: "Polish", fileCodes: ["pl"]),
        GameLanguage(tag: "tr-TR", native: "Türkçe", english: "Turkish", fileCodes: ["tr"]),
        GameLanguage(tag: "sv-SE", native: "Svenska", english: "Swedish", fileCodes: ["sv", "se", "sw"]),
        GameLanguage(tag: "nb-NO", native: "Norsk", english: "Norwegian", fileCodes: ["no", "nb", "nw"]),
        GameLanguage(tag: "da-DK", native: "Dansk", english: "Danish", fileCodes: ["da", "dk"]),
        GameLanguage(tag: "fi-FI", native: "Suomi", english: "Finnish", fileCodes: ["fi"]),
        GameLanguage(tag: "cs-CZ", native: "Čeština", english: "Czech", fileCodes: ["cs", "cz"]),
        GameLanguage(tag: "hu-HU", native: "Magyar", english: "Hungarian", fileCodes: ["hu"]),
        GameLanguage(tag: "el-GR", native: "Ελληνικά", english: "Greek", fileCodes: ["el", "gr"]),
        GameLanguage(tag: "ro-RO", native: "Română", english: "Romanian", fileCodes: ["ro"]),
        GameLanguage(tag: "ar-SA", native: "العربية", english: "Arabic", fileCodes: ["ar"]),
        GameLanguage(tag: "ja-JP", native: "日本語", english: "Japanese", fileCodes: ["ja", "jp"]),
        GameLanguage(tag: "ko-KR", native: "한국어", english: "Korean", fileCodes: ["ko", "kr"]),
        GameLanguage(tag: "zh-Hant", native: "繁體中文", english: "Chinese (traditional)", fileCodes: ["tc", "ch", "zh", "cht", "hk", "tw"]),
        GameLanguage(tag: "zh-Hans", native: "简体中文", english: "Chinese (simplified)", fileCodes: ["sc", "cn", "chs"]),
        GameLanguage(tag: "th-TH", native: "ไทย", english: "Thai", fileCodes: ["th"]),
    ]

    /// The language codes the game's own files carry, sorted ("us", "fr", …); empty when it has
    /// none of ASTRO BOT's language files.
    static func codesInFiles(gamePath: URL?) -> [String] {
        guard var root = gamePath else { return [] }
        if root.lastPathComponent == "eboot.bin" {
            root = root.deletingLastPathComponent()
        }
        let folder = root.appendingPathComponent("data/multi_platformer/text/gfx")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        var codes = Set<String>()
        for name in names {
            guard let range = name.range(of: "_lang_", options: .backwards) else { continue }
            let rest = name[range.upperBound...]
            let code = rest.split(separator: ".").first.map(String.init) ?? ""
            if !code.isEmpty && code.count <= 4 {
                codes.insert(code.lowercased())
            }
        }
        return codes.sorted()
    }

    /// The languages of the list the game's files have, by their codes.
    static func available(codes: [String]) -> Set<String> {
        var tags = Set<String>()
        for language in all where language.fileCodes.contains(where: codes.contains) {
            tags.insert(language.tag)
        }
        return tags
    }

    /// The tag the emulator gets for a setting: "system" is the headset's first language.
    static func tag(for setting: String) -> String {
        if setting.isEmpty || setting == "system" {
            return Locale.preferredLanguages.first ?? "en-US"
        }
        return setting
    }

    static func name(of tag: String) -> String {
        guard let language = all.first(where: { $0.tag == tag }) else { return tag }
        return language.native == language.english ? language.native : "\(language.native) · \(language.english)"
    }
}
