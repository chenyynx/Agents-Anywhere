//
//  BlobatarTraits.swift
//
//  Ported from blobatar 2.8.0 (https://github.com/Alain00/blobatar),
//  MIT License. Copyright (c) 2026 Alain.
//
//  String-addressed trait reads. Keys are an append-only namespace upstream;
//  keeping the same keys and the same ranges is what keeps the seed→look
//  mapping identical.
//

import Foundation

struct BlobatarTraits {
    let state: UInt32

    init(seed: String, normalize: Bool = true) {
        state = BlobatarHash.seedState(seed, normalize: normalize)
    }

    /// Uniform double in [0, 1).
    func value(_ key: String) -> Double {
        BlobatarHash.stream(state, key)
    }

    func num(_ key: String, _ min: Double, _ max: Double) -> Double {
        min + value(key) * (max - min)
    }

    func int(_ key: String, _ min: Int, _ max: Int) -> Int {
        min + Int((value(key) * Double(max - min + 1)).rounded(.down))
    }

    func bool(_ key: String, _ p: Double = 0.5) -> Bool {
        value(key) < p
    }

    func jitter(_ key: String, _ amount: Double) -> Double {
        (value(key) * 2 - 1) * amount
    }
}
