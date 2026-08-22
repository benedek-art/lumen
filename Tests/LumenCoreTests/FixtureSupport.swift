// FixtureSupport.swift
// Loads the golden fixtures generated (and Linux-verified) by scripts/gen-fixtures.py.
// If a fixture is missing, the suite must fail loudly — silence would fake coverage.

import Foundation
import XCTest

struct MissingFixture: Error, CustomStringConvertible {
    let name: String
    var description: String {
        "fixture \(name).json missing — run scripts/gen-fixtures.py"
    }
}

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else {
            XCTFail("fixture \(name).json missing — run scripts/gen-fixtures.py")
            throw MissingFixture(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    /// Untyped access, for fixtures whose shape is a table of sampled values rather
    /// than a model type. Decoding those into `Codable` structs would mean a struct
    /// per section that exists only to be read once.
    static func json(named name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data(name))
        guard let dictionary = object as? [String: Any] else {
            XCTFail("fixture \(name).json is not an object")
            throw MissingFixture(name: name)
        }
        return dictionary
    }
}
