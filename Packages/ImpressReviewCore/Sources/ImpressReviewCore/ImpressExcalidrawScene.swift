import Foundation

/// Read-only Excalidraw scene adapter. Source bytes remain owned by the
/// authorized Vault; no Obsidian plugin scripts or file embeds are executed.
/// Plain .excalidraw JSON and JSON/LZ-String Drawing fences from
/// .excalidraw.md use the same immutable parser.
public enum ImpressExcalidrawReadError: Error, Equatable {
    case invalidScene, missingDrawing, compressedDataUnsupported,
         duplicateID, invalidGeometry, tooLarge, emptySelection
}

/// Serialized Excalidraw rounding algorithm, not a generic UIKit radius.
public struct ImpressExcalidrawRoundness: Codable, Sendable, Equatable {
    public let type: Int
    public let value: Double?
}

public struct ImpressExcalidrawElement: Codable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let angle: Double?
    public let strokeColor: String?
    public let backgroundColor: String?
    public let strokeWidth: Double?
    public let strokeStyle: String?
    /// Arrow endpoint styles live in the serialized source; never infer a
    /// filled triangle/dot from an ordinary line. Nil is read-only legacy data.
    public let startArrowhead: String?
    public let endArrowhead: String?
    public let roundness: ImpressExcalidrawRoundness?
    public let opacity: Double?
    public let text: String?
    /// Native Excalidraw typography and bound-text metadata.
    public let fontSize: Double?
    public let fontFamily: Int?
    public let textAlign: String?
    public let verticalAlign: String?
    public let lineHeight: Double?
    public let containerId: String?
    public let points: [[Double]]?
    public let groupIds: [String]?
    public let frameId: String?
    public let fileId: String?
    /// Authored Excalidraw image-only flip signs and crop viewport.
    public let scale: [Double]?
    public let crop: ImpressExcalidrawImageCrop?
    public let isDeleted: Bool?

    public var isActive: Bool { isDeleted != true }
}

/// Embedded files are never included in text-model excerpts. Only trusted,
/// bounded PNG/JPEG data URLs may be decoded by the read-only UI; remote and
/// SVG data remain unavailable until separately reviewed.
public struct ImpressExcalidrawEmbeddedFile: Decodable, Sendable {
    public let mimeType: String?
    public let dataURL: String?
    public let id: String?
}

public struct ImpressExcalidrawSelection: Sendable {
    public let elementIDs: Set<String>
    public let elements: [ImpressExcalidrawElement]

    /// Model context can describe explicitly chosen structures. Image
    /// pixels, binary attachments and other unselected objects are excluded.
    public func textContextJSON() throws -> String {
        struct Payload: Encodable {
            let elementIDs: [String]
            let elements: [ImpressExcalidrawElement]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(Payload(
            elementIDs: elementIDs.sorted(), elements: elements))
        guard data.count <= 40_000,
              let output = String(data: data, encoding: .utf8) else {
            throw ImpressExcalidrawReadError.tooLarge
        }
        return output
    }
}

public struct ImpressExcalidrawAppState: Decodable, Sendable {
    public let viewBackgroundColor: String?
}

public struct ImpressExcalidrawScene: Decodable, Sendable {
    public let type: String?
    public let version: Int?
    public let elements: [ImpressExcalidrawElement]
    public let files: [String: ImpressExcalidrawEmbeddedFile]?
    public let appState: ImpressExcalidrawAppState?

    /// A Markdown drawing fence must close with the same marker and at least
    /// the opener's width. Different-width backtick/tilde fences are legal in
    /// Obsidian exports; a shorter or different marker is drawing data, not EOF.
    private static func drawingFence(_ line: String)
        -> (marker: Character, width: Int, info: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let body = line.dropFirst(indentation)
        guard let marker = body.first,
              marker == Character(UnicodeScalar(96)!) || marker == "~" else {
            return nil
        }
        let width = body.prefix(while: { $0 == marker }).count
        guard width >= 3 else { return nil }
        return (marker, width,
            String(body.dropFirst(width)).trimmingCharacters(in: .whitespaces))
    }

    /// Parsing never evaluates SVG/HTML, fetches external images, performs
    /// writes or decompresses untrusted payloads through a network service.
    public static func parse(_ bytes: Data,
                             format: ImVaultDocumentFormat) throws -> Self {
        guard bytes.count <= 8 * 1024 * 1024,
              let text = String(data: bytes, encoding: .utf8) else {
            throw ImpressExcalidrawReadError.tooLarge
        }
        let json: String
        switch format {
        case .excalidrawJSON:
            json = text
        case .excalidrawMarkdown:
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            var inDrawing = false
            var collecting = false
            var compressed = false
            var captured: [String] = []
            var found = false
            var opener: (marker: Character, width: Int)?
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !collecting {
                    if trimmed.hasPrefix("#") &&
                       trimmed.drop(while: { $0 == "#" })
                        .trimmingCharacters(in: .whitespaces) == "Drawing" {
                        inDrawing = true
                        continue
                    }
                    guard inDrawing, let candidate = Self.drawingFence(line),
                          candidate.info == "json" ||
                          candidate.info == "compressed-json" else { continue }
                    opener = (candidate.marker, candidate.width)
                    compressed = candidate.info == "compressed-json"
                    collecting = true
                    captured = []
                    continue
                }
                if let closing = Self.drawingFence(line), let opener,
                   closing.marker == opener.marker,
                   closing.width >= opener.width, closing.info.isEmpty {
                    found = true
                    break
                }
                captured.append(line)
            }
            guard found else { throw ImpressExcalidrawReadError.missingDrawing }
            if compressed {
                do {
                    json = try ImpressLZStringBase64.decompress(captured.joined(separator: "\n"))
                } catch ImpressLZStringBase64.Error.exceedsLimit {
                    throw ImpressExcalidrawReadError.tooLarge
                } catch {
                    throw ImpressExcalidrawReadError.invalidScene
                }
            } else {
                json = captured.joined(separator: "\n")
            }
        default:
            throw ImpressExcalidrawReadError.invalidScene
        }
        guard let data = json.data(using: .utf8) else {
            throw ImpressExcalidrawReadError.invalidScene
        }
        let parsed: Self
        do { parsed = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ImpressExcalidrawReadError.invalidScene }
        guard parsed.type == nil || parsed.type == "excalidraw",
              parsed.elements.count <= 5_000 else {
            throw ImpressExcalidrawReadError.tooLarge
        }
        guard (parsed.files?.count ?? 0) <= 512,
              parsed.files?.allSatisfy({ key, file in
                  !key.isEmpty && key.utf8.count <= 256 &&
                  (file.dataURL?.utf8.count ?? 0) <= 8 * 1_024 * 1_024
              }) ?? true else {
            throw ImpressExcalidrawReadError.tooLarge
        }
        let ids = parsed.elements.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              Set(ids).count == ids.count else {
            throw ImpressExcalidrawReadError.duplicateID
        }
        for element in parsed.elements {
            guard element.x.isFinite, element.y.isFinite,
                  element.width.isFinite, element.height.isFinite,
                  (-10_000_000.0...10_000_000.0).contains(element.x),
                  (-10_000_000.0...10_000_000.0).contains(element.y),
                  (0.0...1_000_000.0).contains(element.width),
                  (0.0...1_000_000.0).contains(element.height),
                  element.text.map({ $0.utf8.count <= 400_000 }) ?? true,
                  element.angle.map({ $0.isFinite }) ?? true,
                  element.opacity.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
                  element.strokeWidth.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
                  element.fontSize.map({ $0.isFinite && (1...320).contains($0) }) ?? true,
                  element.lineHeight.map({ $0.isFinite && (0.5...5).contains($0) }) ?? true,
                  element.points.map({ $0.count <= 20_000 &&
                    $0.allSatisfy { point in
                        point.count >= 2 &&
                        point[0].isFinite && point[1].isFinite &&
                        (-10_000_000.0...10_000_000.0).contains(point[0]) &&
                        (-10_000_000.0...10_000_000.0).contains(point[1]) }
                  }) ?? true else {
                throw ImpressExcalidrawReadError.invalidGeometry
            }
        }
        return parsed
    }

    /// Exact element selection is the default. Frame members and grouped
    /// elements only enter context after a separate visible user approval.
    public func selection(ids: Set<String>, expandGroups: Bool = false)
        throws -> ImpressExcalidrawSelection {
        let active = elements.filter(\.isActive)
        let chosen = active.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, chosen.count == ids.count else {
            throw ImpressExcalidrawReadError.emptySelection
        }
        var effective = Set(chosen.map(\.id))
        if expandGroups {
            // One explicit user approval expands the originally selected group
            // IDs and the visible contents of approved frames/containers.
            // Newly encountered group IDs never cascade into unrelated groups.
            let approvedGroups = Set(chosen.flatMap { $0.groupIds ?? [] })
            var frontier = chosen.map(\.id)
            for element in active
                where !approvedGroups.isDisjoint(with: element.groupIds ?? []) {
                if effective.insert(element.id).inserted { frontier.append(element.id) }
            }

            // Use a bounded graph traversal rather than repeatedly scanning
            // all elements for deeply nested frames. Each active ID is visited
            // at most once; cycles cannot cause unbounded expansion.
            let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
            var framedChildren: [String: [String]] = [:]
            var boundText: [String: [String]] = [:]
            for element in active {
                if let frameID = element.frameId {
                    framedChildren[frameID, default: []].append(element.id)
                }
                if element.type == "text", let containerID = element.containerId {
                    boundText[containerID, default: []].append(element.id)
                }
            }
            var offset = 0
            while offset < frontier.count {
                let currentID = frontier[offset]
                offset += 1
                let nested = byID[currentID]?.type == "frame"
                    ? (framedChildren[currentID] ?? []) : []
                for relatedID in nested + (boundText[currentID] ?? []) {
                    if effective.insert(relatedID).inserted {
                        frontier.append(relatedID)
                    }
                }
            }
        }
        return ImpressExcalidrawSelection(elementIDs: effective,
            elements: active.filter { effective.contains($0.id) })
    }
}


    
/// Treat valid Obsidian plugin drawings stored under a plain .md suffix as
/// read-only composite documents, without changing the actual Vault identity.
public enum ImpressObsidianDrawingEnvelope {
    public static func isSupportedDrawing(_ bytes: Data) -> Bool {
        guard bytes.count <= 8 * 1024 * 1024,
              let source = String(data: bytes, encoding: .utf8) else { return false }
        let frontmatter = ImpressFrontmatterReader.parse(source)
        guard frontmatter.state == .valid,
              frontmatter.fields.contains(where: { field in
                  field.name.lowercased() == "excalidraw-plugin" &&
                      field.values.contains(where: { $0.lowercased() == "parsed" })
              }) else { return false }
        // A metadata tag alone must never trigger a drawing: validate the
        // bounded, decompressed Drawing fence and all element IDs/geometries.
        return (try? ImpressExcalidrawScene.parse(bytes,
            format: .excalidrawMarkdown)) != nil
    }
}
