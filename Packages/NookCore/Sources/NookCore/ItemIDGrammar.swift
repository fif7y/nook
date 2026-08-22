// ItemIDGrammar.swift
// The one home for the tag grammar (`status:<bundle>::<title>`, `module:<Name>`,
// `bundle:<id>`). Tags are minted by the enumerator, persisted in the agent
// plist, and parsed by the model — before this file each site rebuilt the
// grammar with its own string hacking.

import Foundation

public extension ItemID {
    enum Parsed: Equatable, Sendable {
        case status(bundle: String, title: String)
        case module(String)
        case bundleKey(String)
        case opaque(String)
    }

    /// Structured view of the tag. `bundleID`/`isSystemModule`/`sectionKey`
    /// stay direct string accessors (hot paths); tests assert they agree with
    /// this parser over a shared corpus.
    var parsed: Parsed {
        if rawValue.hasPrefix("module:") {
            return .module(String(rawValue.dropFirst("module:".count)))
        }
        if rawValue.hasPrefix("bundle:") {
            return .bundleKey(String(rawValue.dropFirst("bundle:".count)))
        }
        if rawValue.hasPrefix("status:") {
            let stripped = rawValue.dropFirst("status:".count)
            if let separator = stripped.range(of: "::") {
                return .status(
                    bundle: String(stripped[..<separator.lowerBound]),
                    title: String(stripped[separator.upperBound...])
                )
            }
        }
        return .opaque(rawValue)
    }

    static func status(bundle: String, title: String) -> ItemID {
        ItemID(rawValue: "status:\(bundle)::\(title)")
    }

    static func module(_ name: String) -> ItemID {
        ItemID(rawValue: "module:\(name)")
    }

    static func bundleKey(_ bundle: String) -> ItemID {
        ItemID(rawValue: "bundle:\(bundle)")
    }

    /// Prefix matching every title variant of a bundle's status tags — the
    /// agent re-mints titles, so "same bundle, any title" is a real query.
    static func statusTagPrefix(bundle: String) -> String {
        "status:\(bundle)::"
    }
}
