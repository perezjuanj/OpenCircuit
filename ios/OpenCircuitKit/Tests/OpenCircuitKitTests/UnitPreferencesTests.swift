import XCTest
@testable import OpenCircuitKit

final class UnitPreferencesTests: XCTestCase {

    // MARK: - TemperatureUnit conversion

    func testZeroCelsiusToFahrenheit() {
        let f = TemperatureUnit.fahrenheit.convert(fromCelsius: 0)
        XCTAssertEqual(f, 32, accuracy: 0.001)
    }

    func testHundredCelsiusToFahrenheit() {
        let f = TemperatureUnit.fahrenheit.convert(fromCelsius: 100)
        XCTAssertEqual(f, 212, accuracy: 0.001)
    }

    func testBodyTempCelsiusToFahrenheit() {
        let f = TemperatureUnit.fahrenheit.convert(fromCelsius: 37)
        XCTAssertEqual(f, 98.6, accuracy: 0.01)
    }

    func testCelsiusIdentity() {
        XCTAssertEqual(TemperatureUnit.celsius.convert(fromCelsius: 36.5), 36.5, accuracy: 0.0001)
    }

    func testCelsiusSymbol() {
        XCTAssertEqual(TemperatureUnit.celsius.symbol, "°C")
    }

    func testFahrenheitSymbol() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.symbol, "°F")
    }

    // MARK: - DistanceUnit conversion

    func testMetrestoKilometres() {
        XCTAssertEqual(DistanceUnit.metric.convert(fromMeters: 5_000), 5.0, accuracy: 0.0001)
    }

    func testMetresToMiles() {
        // 1 mile = 1609.344 m
        XCTAssertEqual(DistanceUnit.imperial.convert(fromMeters: 1_609.344), 1.0, accuracy: 0.0001)
    }

    func testMetricSymbol() {
        XCTAssertEqual(DistanceUnit.metric.symbol, "km")
    }

    func testImperialSymbol() {
        XCTAssertEqual(DistanceUnit.imperial.symbol, "mi")
    }

    // MARK: - UnitsFormatter.temperature

    func testFormatterCelsiusOutput() {
        let s = UnitsFormatter.temperature(36.5, unit: .celsius)
        XCTAssertEqual(s, "36.5 °C")
    }

    func testFormatterFahrenheitOutput() {
        let s = UnitsFormatter.temperature(37, unit: .fahrenheit)
        // 37 °C = 98.6 °F
        XCTAssertEqual(s, "98.6 °F")
    }

    func testFormatterFractionDigitsZero() {
        // Use 36.6 to avoid banker's-rounding ambiguity at .5
        let s = UnitsFormatter.temperature(36.6, unit: .celsius, fractionDigits: 0)
        XCTAssertEqual(s, "37 °C")
    }

    // MARK: - UnitsFormatter.distance

    func testFormatterKilometres() {
        let s = UnitsFormatter.distance(3_200, unit: .metric)
        XCTAssertEqual(s, "3.2 km")
    }

    func testFormatterMiles() {
        let metres = 1_609.344 * 2   // 2 miles
        let s = UnitsFormatter.distance(metres, unit: .imperial)
        XCTAssertEqual(s, "2.0 mi")
    }

    // MARK: - RawValue round-trip (AppStorage compatibility)

    func testTemperatureUnitRawValueRoundTrip() {
        XCTAssertEqual(TemperatureUnit(rawValue: "celsius"), .celsius)
        XCTAssertEqual(TemperatureUnit(rawValue: "fahrenheit"), .fahrenheit)
        XCTAssertNil(TemperatureUnit(rawValue: "kelvin"))
    }

    func testDistanceUnitRawValueRoundTrip() {
        XCTAssertEqual(DistanceUnit(rawValue: "metric"), .metric)
        XCTAssertEqual(DistanceUnit(rawValue: "imperial"), .imperial)
    }
}
