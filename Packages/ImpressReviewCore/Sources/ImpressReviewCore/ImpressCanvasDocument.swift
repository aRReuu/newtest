import Foundation

/// JSON Canvas 1.0 read-only data model. Original bytes stay authoritative
/// in the Vault; decoding is never a rewriting, layout or execution mechanism.
/// See https://github.com/obsidianmd/jsoncanvas/blob/main/spec/1.0.md
public enum ImpressCanvasError: Error, Equatable {
    case invalidDocument, tooLarge, duplicateID, invalidReference,
         invalidGeometry, emptySelection
}

public struct ImpressCanvasNode: Codable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let text: String?
    public let file: String?
    public let subpath: String?
    public let url: String?
    public let label: String?
    public let background: String?
    public let backgroundStyle: String?
    public let color: String?

    public var isKnownType: Bool {
        ["text", "file", "link", "group"].contains(type)
    }
}

public struct ImpressCanvasEdge: Codable, Equatable, Sendable {
    public let id: String
    public let fromNode: String
    public let toNode: String
    public let fromSide: String?
    public let toSide: String?
    public let fromEnd: String?
    public let toEnd: String?
    public let label: String?
    public let color: String?
}

public struct ImpressCanvasSelection: Sendable {
    public let nodeIDs: Set<String>
    public let nodes: [ImpressCanvasNode]
    public let edges: [ImpressCanvasEdge]

    /// Explicit text/structural graph data only. This is NOT visual
    /// comprehension; image pixels are never loaded by this model.
    public func serializedJSON() throws -> String {
        struct Payload: Encodable {
            let nodeIDs: [String]
            let nodes: [ImpressCanvasNode]
            let edges: [ImpressCanvasEdge]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(Payload(nodeIDs: nodeIDs.sorted(),
            nodes: nodes, edges: edges))
        guard data.count <= 40_000,
              let text = String(data: data, encoding: .utf8) else {
            throw ImpressCanvasError.tooLarge
        }
        return text
    }
}

public struct ImpressCanvasDocument: Decodable, Sendable {
    public let nodes: [ImpressCanvasNode]
    public let edges: [ImpressCanvasEdge]

    enum CodingKeys: String, CodingKey { case nodes, edges }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decodeIfPresent([ImpressCanvasNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([ImpressCanvasEdge].self, forKey: .edges) ?? []
    }

    public static func parse(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 8 * 1_024 * 1_024 else {
            throw ImpressCanvasError.tooLarge
        }
        let parsed: Self
        do { parsed = try JSONDecoder().decode(Self.self, from: bytes) }
        catch { throw ImpressCanvasError.invalidDocument }
        guard parsed.nodes.count <= 2_000, parsed.edges.count <= 6_000
        else { throw ImpressCanvasError.tooLarge }
        let ids = parsed.nodes.map(\.id)
        let edgeIDs = parsed.edges.map(\.id)
        guard Set(ids).count == ids.count,
              Set(edgeIDs).count == edgeIDs.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              edgeIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else { throw ImpressCanvasError.duplicateID }
        for node in parsed.nodes {
            guard (-10_000_000...10_000_000).contains(node.x),
                  (-10_000_000...10_000_000).contains(node.y),
                  (1...1_000_000).contains(node.width),
                  (1...1_000_000).contains(node.height),
                  node.text.map({ $0.utf8.count <= 400_000 }) ?? true else {
                throw ImpressCanvasError.invalidGeometry
            }
            // No automatic file or remote URL following. Unknown plugin
            // node types remain visible to the UI as unsupported nodes.
        }
        let validIDs = Set(ids)
        guard parsed.edges.allSatisfy({
            validIDs.contains($0.fromNode) && validIDs.contains($0.toNode)
        }) else { throw ImpressCanvasError.invalidReference }
        return parsed
    }

    /// Selecting one node cannot silently expand another. For an explicitly
    /// selected group, expansion needs a separate, visible UI approval.
    /// Draw order follows the source JSON array (ascending z-index).
    public func selection(nodeIDs: Set<String>,
                          includeGroupMembers: Bool = false) throws -> ImpressCanvasSelection {
        let requested = nodes.filter { nodeIDs.contains($0.id) }
        guard !requested.isEmpty else { throw ImpressCanvasError.emptySelection }
        var effective = Set(requested.map(\.id))
        if includeGroupMembers {
            for group in requested where group.type == "group" {
                for node in nodes where node.id != group.id {
                    let midX = Double(node.x) + Double(node.width) / 2
                    let midY = Double(node.y) + Double(node.height) / 2
                    if midX >= Double(group.x) &&
                       midY >= Double(group.y) &&
                       midX <= Double(group.x) + Double(group.width) &&
                       midY <= Double(group.y) + Double(group.height) {
                        effective.insert(node.id)
                    }
                }
            }
        }
        let kept = nodes.filter { effective.contains($0.id) }
        let relevant = edges.filter {
            effective.contains($0.fromNode) && effective.contains($0.toNode)
        }
        return ImpressCanvasSelection(nodeIDs: effective,
            nodes: kept, edges: relevant)
    }
}