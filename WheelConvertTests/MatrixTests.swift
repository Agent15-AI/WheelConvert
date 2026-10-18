import XCTest
@testable import WheelConvert

final class MatrixTests: XCTestCase {
    func testNoSelfConversions() {
        for (input, output) in ConversionMatrix.allPairs { XCTAssertNotEqual(input, output) }
    }
}
