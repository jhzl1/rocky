import CryptoKit
import Foundation
import JavaScriptCore
import RockyKit
import SwiftUI

/// DIFF-04: code tokens from Prism, vendored in `Resources/Prism/prism-bundle.js` (its version and license are in the
/// bundle's header and the root README) and run in JavaScriptCore, as Textual does internally. One map of token kinds
/// for the diff and the editor (`Theme.syntax`).
///
/// An actor on a serial queue of its own, not on the cooperative pool: tokenizing a large file keeps its thread busy
/// for tens of milliseconds, and a busy pool stops terminal output (`BlockingWorkExecutor`). Results are cached by
/// the text's SHA-256, so a diff that refreshes with the same content does not run Prism again.
actor SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    /// Longer texts stay plain: Prism's regular expressions over megabytes would hold the queue for seconds (the plan's
    /// decision for FIL-06's large files).
    static let maxLength = 1_000_000
    private static let cacheLimit = 64

    /// JavaScriptCore's Objective-C values are autoreleased: each job drains its own pool.
    private let queue = DispatchSerialQueue(label: "rocky.syntax-highlighter", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var context: JSContext?
    private var tokenize: JSValue?
    /// Loading failed once (no bundle, a script error): every text stays plain rather than trying again.
    private var isUnavailable = false
    private var cache: [CacheKey: [SyntaxToken]] = [:]
    /// Oldest first, for eviction past `cacheLimit`.
    private var cacheOrder: [CacheKey] = []

    private struct CacheKey: Hashable {
        let language: String
        let digest: SHA256.Digest
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// The grammar for `path`, or nil for plain text (DIFF-04: from the extension).
    static func language(forPath path: String) -> String? {
        SyntaxLanguage.language(forPath: path)
    }

    /// `text`'s tokens in `language`, in order, with UTF-16 ranges; empty for an unknown language, a text over
    /// `maxLength`, or when Prism is unavailable. Plain text is left out.
    func tokens(for text: String, language: String) -> [SyntaxToken] {
        guard !text.isEmpty, text.utf16.count <= Self.maxLength else { return [] }
        let key = CacheKey(language: language, digest: SHA256.hash(data: Data(text.utf8)))
        if let cached = cache[key] { return cached }
        let tokens = run(text: text, language: language)
        cache[key] = tokens
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
        return tokens
    }

    private func run(text: String, language: String) -> [SyntaxToken] {
        guard let context = loadedContext(), let tokenize else { return [] }
        let result: JSValue? = tokenize.call(withArguments: [text, language])
        if context.exception != nil {
            context.exception = nil
            return []
        }
        // A flat list of start, end and kind, three numbers per token.
        guard let numbers = result?.toArray() as? [NSNumber] else { return [] }
        var tokens: [SyntaxToken] = []
        tokens.reserveCapacity(numbers.count / 3)
        var index = 0
        while index + 2 < numbers.count {
            let start = numbers[index].intValue
            let end = numbers[index + 1].intValue
            if end > start, let kind = SyntaxKind(rawValue: numbers[index + 2].intValue), kind != .plain {
                tokens.append(SyntaxToken(range: start..<end, kind: kind))
            }
            index += 3
        }
        return tokens
    }

    /// The context with Prism and Rocky's glue loaded, made on first use.
    private func loadedContext() -> JSContext? {
        if let context { return context }
        guard !isUnavailable else { return nil }
        let made: JSContext? = JSContext()
        guard let url = Bundle.module.url(forResource: "prism-bundle", withExtension: "js", subdirectory: "Prism"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = made else {
            isUnavailable = true
            return nil
        }
        context.evaluateScript(source, withSourceURL: url)
        context.evaluateScript(Self.glue)
        let function: JSValue? = context.objectForKeyedSubscript("rockyTokenize")
        guard context.exception == nil, let function, !function.isUndefined else {
            isUnavailable = true
            return nil
        }
        self.context = context
        self.tokenize = function
        return context
    }

    /// Walks Prism's token stream into start, end and kind triples (`SyntaxKind`'s raw values), in UTF-16 offsets. A
    /// token's kind is the first known name from the innermost token out, its own type before its aliases, so a
    /// template string's `${…}` stays plain (interpolation) while its text is a string. Text outside every token, and
    /// punctuation and operators, stay plain and are left out.
    private static let glue = """
    var rockyKinds = {
      punctuation: 0, operator: 0, interpolation: 0, 'interpolation-punctuation': 0, parameter: 0,
      keyword: 1, boolean: 1, atrule: 1, important: 1, tag: 1, rule: 1, selector: 1, title: 1, directive: 1, 'null': 1, nil: 1,
      string: 2, char: 2, regex: 2, 'template-string': 2, 'string-literal': 2, 'attr-value': 2, url: 2, 'code-snippet': 2, code: 2,
      number: 3, constant: 3, unit: 3, hexcode: 3,
      comment: 4, prolog: 4, doctype: 4, cdata: 4, shebang: 4,
      'function': 5, 'function-definition': 5, method: 5, property: 5, 'attr-name': 5, key: 5, macro: 5, decorator: 5, annotation: 5,
      'class-name': 6, builtin: 6, namespace: 6, variable: 6, symbol: 6
    };
    function rockyKindOf(chain) {
      for (var i = chain.length - 1; i >= 0; i--) {
        var names = chain[i];
        for (var j = 0; j < names.length; j++) {
          var kind = rockyKinds[names[j]];
          if (kind !== undefined) { return kind; }
        }
      }
      return 0;
    }
    function rockyTokenize(text, language) {
      var grammar = Prism.languages[language];
      if (!grammar) { return []; }
      var out = [];
      var offset = 0;
      function walk(stream, chain) {
        for (var i = 0; i < stream.length; i++) {
          var item = stream[i];
          if (typeof item === 'string') {
            if (chain.length > 0 && item.length > 0) {
              var kind = rockyKindOf(chain);
              if (kind > 0) { out.push(offset, offset + item.length, kind); }
            }
            offset += item.length;
            continue;
          }
          var names = [item.type].concat(item.alias ? (Array.isArray(item.alias) ? item.alias : [item.alias]) : []);
          var content = item.content;
          walk(Array.isArray(content) ? content : [content], chain.concat([names]));
        }
      }
      walk(Prism.tokenize(text, grammar), []);
      return out;
    }
    """
}

/// A diff tab's tokens by line (DIFF-02, DIFF-04): the new side by new line number, which context and added rows use,
/// and the removed rows' by old line number.
struct DiffTokens: Sendable {
    var newSide: [Int: [SyntaxToken]] = [:]
    var oldSide: [Int: [SyntaxToken]] = [:]

    func tokens(for line: DiffLine) -> [SyntaxToken] {
        switch line.kind {
        case .removed: line.oldNumber.flatMap { oldSide[$0] } ?? []
        case .added, .context: line.newNumber.flatMap { newSide[$0] } ?? []
        }
    }
}

extension SyntaxHighlighter {
    /// The tokens of a diff tab, all computed on the highlighter's queue. The new side comes from the whole worktree
    /// file when it was read, so an expanded unchanged run and a comment opened above a hunk color right; else from
    /// each hunk's context and added lines. The old side comes from each hunk's context and removed lines, the only
    /// old text a patch has.
    func diffTokens(file: FileDiff, newLines: [String]?, language: String) -> DiffTokens {
        var result = DiffTokens()
        if let newLines {
            for (index, tokens) in lineTokens(newLines, language: language).enumerated() where !tokens.isEmpty {
                result.newSide[index + 1] = tokens
            }
        }
        for hunk in file.hunks {
            if newLines == nil {
                let newSide = hunk.lines.filter { $0.kind != .removed }
                for (line, tokens) in zip(newSide, lineTokens(newSide.map(\.text), language: language)) where !tokens.isEmpty {
                    if let number = line.newNumber { result.newSide[number] = tokens }
                }
            }
            let oldSide = hunk.lines.filter { $0.kind != .added }
            guard oldSide.contains(where: { $0.kind == .removed }) else { continue }
            for (line, tokens) in zip(oldSide, lineTokens(oldSide.map(\.text), language: language)) where !tokens.isEmpty {
                if line.kind == .removed, let number = line.oldNumber { result.oldSide[number] = tokens }
            }
        }
        return result
    }

    private func lineTokens(_ lines: [String], language: String) -> [[SyntaxToken]] {
        SyntaxToken.split(tokens(for: lines.joined(separator: "\n"), language: language), lines: lines)
    }
}

/// Draws one line of code with its tokens' colors (`Theme.syntax`), for the diff's rows. A tab shows as four spaces,
/// so every row measures in whole columns (`columns(of:)`), and a CRLF file's `\r` is not drawn.
enum HighlightedLine {
    static let tabWidth = 4

    static func attributed(_ text: String, tokens: [SyntaxToken]) -> AttributedString {
        var units = Array(text.utf16)
        if units.last == UInt16(UInt8(ascii: "\r")) { units.removeLast() }
        var result = AttributedString()
        var position = 0
        for token in tokens {
            let start = min(max(token.range.lowerBound, position), units.count)
            let end = min(token.range.upperBound, units.count)
            guard end > start else { continue }
            append(units[position..<start], color: nil, to: &result)
            append(units[start..<end], color: Theme.syntax(token.kind), to: &result)
            position = end
        }
        append(units[position..<units.count], color: nil, to: &result)
        return result
    }

    /// How many columns the line takes as drawn: tabs as `tabWidth`, the `\r` left out.
    static func columns(of text: String) -> Int {
        var count = 0
        for unit in text.utf16 {
            switch unit {
            case UInt16(UInt8(ascii: "\t")): count += tabWidth
            case UInt16(UInt8(ascii: "\r")): break
            default: count += 1
            }
        }
        return count
    }

    private static func append(_ units: ArraySlice<UInt16>, color: Color?, to result: inout AttributedString) {
        guard !units.isEmpty else { return }
        let text = String(decoding: units, as: UTF16.self)
        var piece = AttributedString(text.contains("\t") ? text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth)) : text)
        if let color { piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = color }
        result.append(piece)
    }
}
