//
//  BlobatarHash.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  Seed hashing, kept byte-for-byte compatible with the JavaScript original so
//  the same name produces the same creature in both renderers.
//

import Foundation

enum BlobatarHash {
    /// NFC → trim → lowercase, so inputs a person considers equal hash equally.
    static func normalizeSeed(_ seed: String) -> String {
        seed.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Hashes the seed once into a reusable 32-bit state.
    ///
    /// The initial XOR uses `utf16.count`, not `count`: the JavaScript source
    /// reads `s.length`, which counts UTF-16 code units, and switching to
    /// glyphs would move every existing face.
    static func seedState(_ seed: String, normalize: Bool = true) -> UInt32 {
        let value = normalize ? normalizeSeed(seed) : seed
        return feed(1779033703 ^ UInt32(value.utf16.count), Array(value.utf8))
    }

    /// Derives one uniform double in [0, 1) for `key`, independent of every other key.
    static func stream(_ state: UInt32, _ key: String) -> Double {
        let mixed = finalize(feed(feed(state, [0xFF]), Array(key.utf8)))
        return Double(mixed) / 4294967296.0
    }

    /// Mixes bytes into a 32-bit state (FNV-style stepping with murmur's constants).
    private static func feed(_ initial: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var h = initial
        for byte in bytes {
            h = (h ^ UInt32(byte)) &* 3432918353
            h = (h << 13) | (h >> 19)
        }
        return h
    }

    /// murmur3 fmix32 — a bijection on uint32 with full avalanche.
    private static func finalize(_ initial: UInt32) -> UInt32 {
        var h = initial
        h = (h ^ (h >> 16)) &* 2246822507
        h = (h ^ (h >> 13)) &* 3266489909
        return h ^ (h >> 16)
    }
}
