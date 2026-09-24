import Foundation

// Fails when a string in the catalog has no translation for the given language, or is no longer used.
// Usage: swift tools/check_strings.swift Resources/Localizable.xcstrings ja

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: check_strings.swift <catalog.xcstrings> <language>\n".utf8))
    exit(2)
}
let language = arguments[2]
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let strings = catalog["strings"] as? [String: [String: Any]]
else {
    FileHandle.standardError.write(Data("error: \(arguments[1]) is not a String Catalog\n".utf8))
    exit(1)
}

var problems: [String] = []
for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
    if entry["shouldTranslate"] as? Bool == false { continue }
    if entry["extractionState"] as? String == "stale" {
        problems.append("unused:     \(key.debugDescription)")
        continue
    }
    let localizations = entry["localizations"] as? [String: Any]
    let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
    if unit?["state"] as? String != "translated" || (unit?["value"] as? String ?? "").isEmpty {
        problems.append("missing \(language): \(key.debugDescription)")
    }
}

if problems.isEmpty {
    print("  \(strings.count) strings, all translated into \(language)")
} else {
    FileHandle.standardError.write(
        Data((problems + ["error: \(problems.count) string problems"]).joined(separator: "\n").utf8 + Data("\n".utf8)))
    exit(1)
}
