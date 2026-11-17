import Carbon
import Foundation

struct InputSourceInfo: Hashable {
    let id: String
    let inputModeID: String?
    let name: String
    let isASCIICapable: Bool
}

@MainActor
enum InputSourceService {
    static func selectableKeyboardSources() -> [InputSourceInfo] {
        var seen = Set<SourceIdentifier>()
        return keyboardSources().compactMap { source in
            guard let info = information(for: source),
                  seen.insert(SourceIdentifier(info)).inserted else { return nil }
            return info
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if $0.id != $1.id { return $0.id < $1.id }
            return ($0.inputModeID ?? "") < ($1.inputModeID ?? "")
        }
    }

    static func current() -> InputSourceInfo? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return information(for: source)
    }

    @discardableResult
    static func select(_ source: InputSourceInfo) -> Bool {
        select(id: source.id, inputModeID: source.inputModeID)
    }

    @discardableResult
    static func select(id: String, inputModeID: String?) -> Bool {
        if matches(current(), id: id, inputModeID: inputModeID) { return true }
        let sources = keyboardSources()
        guard let target = matchingSource(in: sources, id: id, inputModeID: inputModeID),
              let targetInfo = information(for: target) else { return false }
        if matches(current(), id: targetInfo.id, inputModeID: targetInfo.inputModeID) { return true }

        _ = TISSelectInputSource(target)
        if matches(current(), id: targetInfo.id, inputModeID: targetInfo.inputModeID) { return true }

        if needsKeyboardLayoutBridge(target),
           let bridge = preferredEnglishSource(in: sources),
           let bridgeInfo = information(for: bridge),
           SourceIdentifier(bridgeInfo) != SourceIdentifier(targetInfo) {
            if !matches(current(), id: bridgeInfo.id, inputModeID: bridgeInfo.inputModeID) {
                _ = TISSelectInputSource(bridge)
            }
            if matches(current(), id: targetInfo.id, inputModeID: targetInfo.inputModeID) { return true }
            _ = TISSelectInputSource(target)
        }

        return matches(current(), id: targetInfo.id, inputModeID: targetInfo.inputModeID)
    }

    static func defaultEnglishSource() -> InputSourceInfo? {
        preferredEnglishSource(in: keyboardSources()).flatMap(information(for:))
    }

    static func matches(_ source: InputSourceInfo?, id: String, inputModeID: String?) -> Bool {
        guard let source, source.id == id else { return false }
        return inputModeID == nil || source.inputModeID == inputModeID
    }

    private struct SourceIdentifier: Hashable {
        let id: String
        let inputModeID: String?

        init(_ source: InputSourceInfo) {
            id = source.id
            inputModeID = source.inputModeID
        }
    }

    private static func keyboardSources() -> [TISInputSource] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
        else { return [] }
        return (0..<CFArrayGetCount(list)).map { index in
            Unmanaged<TISInputSource>.fromOpaque(CFArrayGetValueAtIndex(list, index)).takeUnretainedValue()
        }.filter {
            boolProperty($0, kTISPropertyInputSourceIsSelectCapable)
                && boolProperty($0, kTISPropertyInputSourceIsEnabled)
        }
    }

    private static func matchingSource(
        in sources: [TISInputSource], id: String, inputModeID: String?
    ) -> TISInputSource? {
        let candidates = sources.filter {
            matches(information(for: $0), id: id, inputModeID: inputModeID)
        }
        guard inputModeID == nil else { return candidates.first }
        if let selected = current(), let matchingCurrent = candidates.first(where: {
            information(for: $0).map(SourceIdentifier.init) == SourceIdentifier(selected)
        }) {
            return matchingCurrent
        }
        return candidates.first { stringProperty($0, kTISPropertyInputModeID) == nil }
            ?? candidates.first
    }

    private static func preferredEnglishSource(in sources: [TISInputSource]) -> TISInputSource? {
        let layouts = sources.filter {
            stringProperty($0, kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String
                && boolProperty($0, kTISPropertyInputSourceIsASCIICapable)
        }
        for identifier in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            if let source = layouts.first(where: {
                stringProperty($0, kTISPropertyInputSourceID) == identifier
            }) { return source }
        }
        return layouts.first
    }

    private static func needsKeyboardLayoutBridge(_ source: TISInputSource) -> Bool {
        guard stringProperty(source, kTISPropertyInputSourceType) != kTISTypeKeyboardLayout as String
        else { return false }
        let languages = property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
        let hasCJKVLanguage = languages.contains {
            let language = $0.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            return ["zh", "ja", "ko", "vi"].contains(language.map(String.init) ?? "")
        }
        return hasCJKVLanguage || !boolProperty(source, kTISPropertyInputSourceIsASCIICapable)
    }

    private static func information(for source: TISInputSource) -> InputSourceInfo? {
        guard let identifier = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        return InputSourceInfo(
            id: identifier,
            inputModeID: stringProperty(source, kTISPropertyInputModeID),
            name: stringProperty(source, kTISPropertyLocalizedName) ?? identifier,
            isASCIICapable: boolProperty(source, kTISPropertyInputSourceIsASCIICapable)
        )
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        property(source, key) as? String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        property(source, key) as? Bool ?? false
    }
}
