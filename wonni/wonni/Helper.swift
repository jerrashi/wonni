//
//  Helper.swift
//  A small collection of quick helpers to avoid repeating the same old code.
//
//  Created by Paul Hudson on 23/06/2019.
//  Copyright © 2019 Hacking with Swift. All rights reserved.
//

import UIKit

enum BundleDecodeError: LocalizedError {
    case missingResource(String)
    case unreadable(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let file): return "Failed to locate \(file) in bundle."
        case .unreadable(let file): return "Failed to load \(file) from bundle."
        case .malformed(let file): return "Failed to decode \(file) from bundle."
        }
    }
}

extension Bundle {
    // T is a generic type placeholder
    // T: Decodable means T must conform to the Decodable protocol
    // First input is the type of the object expected (model that we will use)
    // Throws instead of crashing (#65) — a corrupted/missing bundled resource
    // is recoverable (caller can fall back or surface an error), not grounds
    // for a hard crash on first launch.
    func decode<T: Decodable>(_ type: T.Type, from file: String) throws -> T {
        guard let url = self.url(forResource: file, withExtension: nil) else {
            throw BundleDecodeError.missingResource(file)
        }

        guard let data = try? Data(contentsOf: url) else {
            throw BundleDecodeError.unreadable(file)
        }

        let decoder = JSONDecoder()

        guard let loaded = try? decoder.decode(T.self, from: data) else {
            throw BundleDecodeError.malformed(file)
        }

        return loaded
    }
}
