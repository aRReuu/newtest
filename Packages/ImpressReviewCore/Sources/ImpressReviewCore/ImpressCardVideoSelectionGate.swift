import Foundation

/// An editor-scoped token gate. Picker callbacks and offline export completions
/// can outlive an editor, arrive out of order, or belong to a different card.
/// This only controls *draft adoption*, never writes WCDB or FSRS.
public struct ImpressCardVideoSelectionGate: Sendable {
    public enum Kind: String, Sendable { case image, video }
    public struct Ticket: Hashable, Sendable {
        public let cardID: UUID
        public let expectedContentRevision: Int
        public let selectionID: UUID
        public let kind: Kind
    }
    public enum Phase: Equatable, Sendable {
        case idle, picking, selected, exporting, ready, saving
    }
    public enum Failure: Error, Equatable {
        case invalidRevision, saveInProgress, staleSelection, invalidTransition
    }

    public private(set) var phase: Phase = .idle
    public private(set) var prepared: Ticket?
    public private(set) var active: Ticket?
    private var cardID: UUID?
    private var expectedRevision: Int?

    public init() {}

    /// Reusing an editor for a new content revision invalidates all late callbacks.
    /// Returning to the same revision preserves an already prepared draft.
    public mutating func bind(cardID: UUID, expectedContentRevision: Int) throws {
        guard expectedContentRevision >= 0 else { throw Failure.invalidRevision }
        guard phase != .saving else { throw Failure.saveInProgress }
        if self.cardID != cardID || expectedRevision != expectedContentRevision {
            reset()
        }
        self.cardID = cardID
        expectedRevision = expectedContentRevision
    }

    @discardableResult
    public mutating func beginSelection(kind: Kind, selectionID: UUID = UUID()) throws -> Ticket {
        guard phase != .saving else { throw Failure.saveInProgress }
        guard let cardID, let expectedRevision else { throw Failure.invalidTransition }
        let ticket = Ticket(cardID: cardID, expectedContentRevision: expectedRevision,
                            selectionID: selectionID, kind: kind)
        active = ticket
        phase = .picking
        return ticket
    }

    public mutating func pickerDidLoad(_ ticket: Ticket) throws {
        try require(ticket, phase: .picking)
        phase = .selected
    }

    public mutating func beginExport(_ ticket: Ticket) throws {
        try require(ticket, phase: .selected)
        phase = .exporting
    }

    /// The caller must validate exported bytes and cover before calling this.
    /// A late iCloud/export completion can never replace a newer selection.
    public mutating func didVerifyExport(_ ticket: Ticket) throws {
        try require(ticket, phase: .exporting)
        prepared = ticket
        phase = .ready
    }

    /// Cancellation never removes the previously prepared draft or saved card.
    @discardableResult
    public mutating func cancel(_ ticket: Ticket) -> Bool {
        guard active == ticket, phase != .saving else { return false }
        active = prepared
        phase = prepared == nil ? .idle : .ready
        return true
    }

    /// The only transition that permits the caller to attempt a WCDB content CAS.
    public mutating func beginSave(_ ticket: Ticket) throws {
        try require(ticket, phase: .ready)
        guard prepared == ticket else { throw Failure.staleSelection }
        phase = .saving
    }

    /// A failed CAS or app error must leave the prepared draft available to retry.
    public mutating func finishSave(_ ticket: Ticket, didCommit: Bool) throws {
        try require(ticket, phase: .saving)
        if didCommit {
            prepared = nil
            active = nil
            phase = .idle
        } else {
            phase = .ready
        }
    }

    public mutating func dismissEditor() {
        reset()
        cardID = nil
        expectedRevision = nil
    }

    private mutating func reset() {
        active = nil
        prepared = nil
        phase = .idle
    }

    private func require(_ ticket: Ticket, phase expected: Phase) throws {
        guard phase == expected else { throw Failure.invalidTransition }
        guard active == ticket, cardID == ticket.cardID,
              expectedRevision == ticket.expectedContentRevision else {
            throw Failure.staleSelection
        }
    }
}
