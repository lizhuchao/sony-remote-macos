import Foundation

func l10n(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func l10n(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: l10n(key), locale: Locale.current, arguments: arguments)
}
