import Testing
@testable import ReKapCore

struct EditorTests {
    @Test func trimEditsPreserveAUsableFiniteSelection() {
        var range = EditorTrimRange(duration: 10)
        range.setStart(3)
        range.setEnd(8)
        let selected = range
        for value in [Double.nan, .infinity, -.infinity] {
            range.setStart(value)
            range.setEnd(value)
            #expect(range == selected)
        }
        range.setStart(100)
        #expect(range.isValid)
        #expect(abs(range.start - 7.99) < 0.0001)
        range.setEnd(-100)
        #expect(range.isValid)
        range.reset()
        #expect(range.start == 0 && range.end == 10)
    }

    @Test func invalidMediaCannotProduceAnExportableRange() {
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            var range = EditorTrimRange(duration: duration)
            range.setStart(1)
            range.setEnd(2)
            #expect(!range.isValid)
            #expect(range.start == 0 && range.end == 0)
        }
    }

    @Test func subFrameClipsRemainEditable() {
        var range = EditorTrimRange(duration: 0.005)
        range.setStart(1)
        range.setEnd(-1)
        #expect(range.isValid)
        #expect(range.start == 0 && range.end == 0.005)
    }

    @Test func defaultExportRatePreservesVariableRateCaptureFrames() {
        #expect(EditorFrameRates.preferred(for: 51.7) == 60)
        #expect(EditorFrameRates.preferred(for: 29.97) == 30)
        #expect(EditorFrameRates.preferred(for: 50.00001) == 50)
        #expect(EditorFrameRates.preferred(for: 120) == 60)
        for value in [Float.nan, .infinity, -.infinity, 0, -1] {
            #expect(EditorFrameRates.preferred(for: value) == 30)
        }
    }

}
