import Foundation
import XCTest
@testable import ImpressReviewCore

final class ImpressCardVideoSelectionGateTests: XCTestCase {
    let a = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let b = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func ready(_ gate: inout ImpressCardVideoSelectionGate,
                       kind: ImpressCardVideoSelectionGate.Kind = .video) throws
        -> ImpressCardVideoSelectionGate.Ticket {
        let ticket = try gate.beginSelection(kind: kind)
        try gate.pickerDidLoad(ticket)
        try gate.beginExport(ticket)
        try gate.didVerifyExport(ticket)
        return ticket
    }

    func testPickerCancelKeepsPriorReadyDraft() throws {
        var gate = ImpressCardVideoSelectionGate()
        try gate.bind(cardID: a, expectedContentRevision: 4)
        let old = try ready(&gate)
        let new = try gate.beginSelection(kind: .video)
        XCTAssertTrue(gate.cancel(new))
        XCTAssertEqual(gate.prepared, old)
        XCTAssertEqual(gate.phase, .ready)
    }

    func testLateICloudCallbackCannotSwitchCards() throws {
        var gate = ImpressCardVideoSelectionGate()
        try gate.bind(cardID: a, expectedContentRevision: 4)
        let old = try gate.beginSelection(kind: .video)
        try gate.bind(cardID: b, expectedContentRevision: 5)
        XCTAssertThrowsError(try gate.pickerDidLoad(old))
        XCTAssertNil(gate.prepared)
    }

    func testLateOldExportCannotOverwriteNewSelection() throws {
        var gate = ImpressCardVideoSelectionGate()
        try gate.bind(cardID: a, expectedContentRevision: 4)
        let old = try gate.beginSelection(kind: .video)
        try gate.pickerDidLoad(old)
        try gate.beginExport(old)
        let replacement = try gate.beginSelection(kind: .image)
        XCTAssertThrowsError(try gate.didVerifyExport(old))
        try gate.pickerDidLoad(replacement)
        try gate.beginExport(replacement)
        try gate.didVerifyExport(replacement)
        XCTAssertEqual(gate.prepared?.kind, .image)
    }

    func testRepeatedSaveDeniedUntilCASResult() throws {
        var gate = ImpressCardVideoSelectionGate()
        try gate.bind(cardID: a, expectedContentRevision: 4)
        let ticket = try ready(&gate)
        try gate.beginSave(ticket)
        XCTAssertThrowsError(try gate.beginSave(ticket))
        XCTAssertThrowsError(try gate.beginSelection(kind: .video))
        XCTAssertFalse(gate.cancel(ticket))
        try gate.finishSave(ticket, didCommit: true)
        XCTAssertNil(gate.prepared)
    }

    func testFailedCASAllowsExactSameReadyDraftRetry() throws {
        var gate = ImpressCardVideoSelectionGate()
        try gate.bind(cardID: a, expectedContentRevision: 4)
        let ticket = try ready(&gate)
        try gate.beginSave(ticket)
        try gate.finishSave(ticket, didCommit: false)
        XCTAssertEqual(gate.prepared, ticket)
        try gate.beginSave(ticket)
        try gate.finishSave(ticket, didCommit: true)
    }

    func testDifferentRevisionInvalidatesPreviouslyPreparedDraft() throws {
        var gate = ImpressCardVideoSelectionGate()
        try gate.bind(cardID: a, expectedContentRevision: 4)
        let old = try ready(&gate)
        try gate.bind(cardID: a, expectedContentRevision: 5)
        XCTAssertNil(gate.prepared)
        XCTAssertThrowsError(try gate.beginSave(old))
    }

    func testInvalidRevisionAndUnboundSelectionDenied() throws {
        var gate = ImpressCardVideoSelectionGate()
        XCTAssertThrowsError(try gate.beginSelection(kind: .image))
        XCTAssertThrowsError(try gate.bind(cardID: a, expectedContentRevision: -1))
    }

    func testEditorDismissalInvalidatesAllLateCompletion() throws {
        var gate = ImpressCardVideoSelectionGate()
        try gate.bind(cardID: a, expectedContentRevision: 4)
        let ticket = try gate.beginSelection(kind: .video)
        gate.dismissEditor()
        XCTAssertThrowsError(try gate.pickerDidLoad(ticket))
        XCTAssertFalse(gate.cancel(ticket))
    }
}
