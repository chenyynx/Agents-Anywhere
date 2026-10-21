import SwiftUI

/// Public bridge over Textual's math attachment.
///
/// The host renders assistant markdown outside `StructuredText` (a TextKit 2
/// cell), so it cannot reach the internal `MathAttachment` that the math
/// syntax extension produces. This bridge keeps the host on the same engine
/// as the legacy renderer: the same typographic bounds for measurement and
/// the same view for drawing, with one explicit environment on both sides.
public enum TextualMath {
  /// A math attachment found in parsed markdown.
  public struct Descriptor: Hashable, Sendable {
    public let latex: String
    public let isBlock: Bool

    public init(latex: String, isBlock: Bool) {
      self.latex = latex
      self.isBlock = isBlock
    }
  }

  /// Synchronous typographic metrics for an inline or block formula.
  public struct Metrics: Hashable, Sendable {
    /// The laid-out attachment size at the proposed width.
    public let size: CGSize
    /// The baseline offset the text layout applies to the attachment.
    public let baselineOffset: CGFloat

    public init(size: CGSize, baselineOffset: CGFloat) {
      self.size = size
      self.baselineOffset = baselineOffset
    }
  }

  /// Recognizes the attachment type produced by the `.math` syntax extension.
  public static func descriptor(for attachment: AnyAttachment) -> Descriptor? {
    guard let math = attachment.base as? MathAttachment else { return nil }
    switch math.displayStyle {
    case .inline:
      return Descriptor(latex: math.latex, isBlock: false)
    case .block:
      return Descriptor(latex: math.latex, isBlock: true)
    }
  }

  /// Measures with the same environment `TextualMathView` renders in.
  ///
  /// `fontSize` is the surrounding text's size: the attachment scales it by
  /// `MathProperties.fontScale` exactly as the StructuredText path does.
  public static func metrics(
    latex: String,
    isBlock: Bool,
    fontSize: CGFloat,
    proposalWidth: CGFloat? = nil
  ) -> Metrics {
    let attachment = MathAttachment(
      latex: latex,
      style: isBlock ? .block : .inline
    )
    let environment = TextEnvironmentValues(font: .system(size: fontSize))
    let proposal = proposalWidth.map {
      ProposedViewSize(width: $0, height: nil)
    } ?? ProposedViewSize.unspecified
    return Metrics(
      size: attachment.sizeThatFits(proposal, in: environment),
      baselineOffset: attachment.baselineOffset(in: environment)
    )
  }
}

/// The math view paired with `TextualMath.metrics(latex:isBlock:fontSize:)`.
///
/// Measurement and drawing agree through the font: `MathView` reads
/// `textEnvironment`, whose getter picks up the injected `.font`, and the
/// remaining values (scheme, contrast, math properties) come from the host's
/// real environment rather than defaults.
public struct TextualMathView: View {
  private let latex: String
  private let isBlock: Bool
  private let fontSize: CGFloat

  public init(latex: String, isBlock: Bool, fontSize: CGFloat) {
    self.latex = latex
    self.isBlock = isBlock
    self.fontSize = fontSize
  }

  public var body: some View {
    MathAttachment(latex: latex, style: isBlock ? .block : .inline).body
      .environment(\.font, .system(size: fontSize))
  }
}
