//
//  BlobatarPath+SwiftUI.swift
//
//  Turns the generator's absolute command list into a SwiftUI `Path`. Kept in
//  the view layer so the generator itself stays Foundation-only and testable in
//  the headless package.
//

import SwiftUI

extension BlobatarPath {
    var path: Path {
        var path = Path()
        for command in commands {
            switch command {
            case let .move(x, y):
                path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y):
                path.addLine(to: CGPoint(x: x, y: y))
            case let .quad(cx, cy, x, y):
                path.addQuadCurve(to: CGPoint(x: x, y: y),
                                  control: CGPoint(x: cx, y: cy))
            case let .curve(x1, y1, x2, y2, x, y):
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: x1, y: y1),
                              control2: CGPoint(x: x2, y: y2))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}
