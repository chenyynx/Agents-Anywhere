import SwiftUI

/// A small set of environment values used for resolving dynamic colors.
public struct ColorEnvironmentValues: Hashable, Sendable {
  /// The current color scheme.
  public var colorScheme: ColorScheme

  /// The current color scheme contrast.
  public var colorSchemeContrast: ColorSchemeContrast

  /// Public so a host that builds an attachment outside a Textual view can
  /// supply the same defaults the environment would.
  public init(
    colorScheme: ColorScheme = .light,
    colorSchemeContrast: ColorSchemeContrast = .standard
  ) {
    self.colorScheme = colorScheme
    self.colorSchemeContrast = colorSchemeContrast
  }
}

extension EnvironmentValues {
  var colorEnvironment: ColorEnvironmentValues {
    .init(
      colorScheme: colorScheme,
      colorSchemeContrast: colorSchemeContrast
    )
  }
}
