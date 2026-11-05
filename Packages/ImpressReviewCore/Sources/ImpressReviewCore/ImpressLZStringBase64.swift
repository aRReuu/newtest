import Foundation

/// Strict, bounded reader for the LZ-String Base64 transport used by
/// Obsidian Excalidraw's `compressed-json` Drawing fences. It implements only
/// decompression: never evaluates drawing scripts or follows resource links.
/// Format reference: pieroxy/lz-string (MIT), Obsidian sceneDataUtils.ts.
public enum ImpressLZStringBase64 {
    public enum Error: Swift.Error, Equatable {
        case malformedInput
        case exceedsLimit
    }

    private struct BitReader {
        let symbols: [UInt8]
        var symbolIndex = 0
        var bitIndex = 5

        mutating func read(_ count: Int) -> Int? {
            guard count > 0 && count <= 24 else { return nil }
            var value = 0
            for bit in 0..<count {
                guard symbolIndex < symbols.count else { return nil }
                if symbols[symbolIndex] & (1 << bitIndex) != 0 {
                    value |= (1 << bit)
                }
                bitIndex -= 1
                if bitIndex < 0 {
                    bitIndex = 5
                    symbolIndex += 1
                }
            }
            return value
        }
    }

    /// LZ-String writes UTF-16 code units, not UTF-8 bytes. Convert only
    /// after validating the complete surrogate sequence and output budget.
    public static func decompress(_ base64: String,
                                  maximumUTF8Bytes: Int = 8 * 1_024 * 1_024) throws -> String {
        let source = base64.utf8.filter { $0 != 10 && $0 != 13 }
        guard !source.isEmpty, source.count <= 8 * 1_024 * 1_024,
              maximumUTF8Bytes > 0, source.count % 4 == 0 else {
            throw Error.malformedInput
        }
        var padding = 0
        while padding < 3 && source[source.count - 1 - padding] == 61 {
            padding += 1
        }
        guard !source.prefix(source.count - padding).contains(61) else {
            throw Error.malformedInput
        }
        let alphabetCount = source.count - padding
        var symbols: [UInt8] = []
        symbols.reserveCapacity(alphabetCount)
        for symbol in source.prefix(alphabetCount) {
            let value: UInt8
            switch symbol {
            case 65...90: value = symbol - 65
            case 97...122: value = symbol - 97 + 26
            case 48...57: value = symbol - 48 + 52
            case 43: value = 62
            case 47: value = 63
            default: throw Error.malformedInput
            }
            symbols.append(value)
        }
        guard !symbols.isEmpty else { throw Error.malformedInput }
        var reader = BitReader(symbols: symbols)
        guard let firstToken = reader.read(2), firstToken != 2,
              let firstValue = reader.read(firstToken == 0 ? 8 : 16) else {
            throw Error.malformedInput
        }
        let first = UInt16(firstValue)
        var dictionary: [[UInt16]] = [[], [], [], [first]]
        var output: [UInt16] = [first]
        var previous: [UInt16] = [first]
        var dictionarySize = 4
        var enlargeIn = 4
        var bitWidth = 3
        // Bounds both the output and worst-case intermediate expansions.
        let maxUnits = min(4_000_000, maximumUTF8Bytes)
        while true {
            guard let rawToken = reader.read(bitWidth) else {
                throw Error.malformedInput
            }
            var code = rawToken
            if rawToken == 2 {
                let text = String(decoding: output, as: UTF16.self)
                guard Array(text.utf16) == output else { throw Error.malformedInput }
                guard text.utf8.count <= maximumUTF8Bytes else { throw Error.exceedsLimit }
                return text
            }
            if rawToken == 0 || rawToken == 1 {
                guard let value = reader.read(rawToken == 0 ? 8 : 16) else {
                    throw Error.malformedInput
                }
                dictionary.append([UInt16(value)])
                code = dictionarySize
                dictionarySize += 1
                enlargeIn -= 1
            }
            if enlargeIn == 0 {
                enlargeIn = 1 << bitWidth
                bitWidth += 1
            }
            let entry: [UInt16]
            if code < dictionary.count && !dictionary[code].isEmpty {
                entry = dictionary[code]
            } else if code == dictionarySize {
                entry = previous + [previous[0]]
            } else {
                throw Error.malformedInput
            }
            guard entry.count <= maxUnits - output.count,
                  dictionarySize < 150_000, bitWidth < 24 else {
                throw Error.exceedsLimit
            }
            output.append(contentsOf: entry)
            dictionary.append(previous + [entry[0]])
            dictionarySize += 1
            enlargeIn -= 1
            previous = entry
            if enlargeIn == 0 {
                enlargeIn = 1 << bitWidth
                bitWidth += 1
            }
        }
    }
}
