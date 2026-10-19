#if DEBUG
import Foundation

/// Fixtures for the C5 / M1 TextKit 2 spike.
///
/// `pureParagraph` and `paragraphs3` are plain running text: they exist to
/// compare the engine the product renders with today (Textual / SwiftUI Text)
/// against TextKit 2 at the same column width. `richLong` is the shape of a
/// real assistant reply; it is not a parity gate in M1, only a failure probe
/// for tables, code blocks, lists, quotes and inline styles.
enum TextKitSpikeFixtures {
    static let pureParagraph = """
    The assistant replies in running text that has to wrap across many lines in the column, because that is where height measurement either matches the renderer or drifts by whole lines. A paragraph like this mixes ordinary English sentences with Chinese characters 例如这样的中文段落用来验证换行宽度与行距，以及标点符号在行尾的处理方式。The measurement must be the same engine that will draw the text, or the first frame will reserve the wrong height and the list will overlap the next row. Repeating the sentence a few more times makes the paragraph long enough to produce fifteen to twenty line fragments at the product column width, which is the smallest sample that makes a one-point-per-line error visible. 再补一段中文，让这一段的行数稳定超过十五行，同时包含英文单词、数字 1234567890、以及标点，便于观察断行位置。The spike compares the Textual renderer that ships today with the TextKit 2 stack the same Markdown will move to.
    """

    static let paragraphs3 = """
    First paragraph: the reply opens with a statement that wraps two or three times in the column, so the paragraph gap has to be counted exactly once.

    Second paragraph: 这一段中文继续填充行数，确保每一段都超过两行，这样段间距的误差不会被行高取整掩盖。 It also includes numbers 42 and 8.15 to break the line at different places.

    Third paragraph: the closing sentence is short.
    """

    /// Latin-only control for the line-height question: same body font and
    /// leading, no CJK fallback font in the paragraph.
    static let pureLatin = """
    The assistant replies in running text that has to wrap across many lines in the column, because that is where height measurement either matches the renderer or drifts by whole lines. The measurement must be the same engine that will draw the text, or the first frame will reserve the wrong height and the list will overlap the next row. Repeating the sentence a few more times makes the paragraph long enough to produce fifteen to twenty line fragments at the product column width, which is the smallest sample that makes a one-point-per-line error visible. The spike compares the Textual renderer that ships today with the TextKit 2 stack the same Markdown will move to, and the result decides whether the migration is a drop-in replacement or a re-measurement.
    """

    /// CJK-only control: PingFang fallback metrics differ from SF Pro, and
    /// SwiftUI Text may size the line box from the fallback font.
    static let pureCJK = """
    助手用连续的中文正文回复，这一段刻意写得很长，用来验证在同一个列宽下换行位置与行距是否一致。测量必须由将来真正绘制文本的同一个引擎完成，否则第一帧会预留错误的高度，列表就会和下一行重叠。把这句话再重复几次，让这一段在产品的正文列宽下稳定产生十五到二十个行片段，这是让每行一磅的误差也能被看见的最小样本。这次对照把现在随产品发布的渲染器与即将迁移过去的文本引擎放在一起测量，结果决定迁移是可以直接替换，还是必须重新标定行高与段距。
    """

    /// A single line at the product width: its height is exactly one line box,
    /// with no inter-line spacing to confuse the comparison.
    static let singleLineLatin = "One short line of body text."

    static let singleLineCJK = "一行中文正文。"

    static let richLong = """
    ## Assistant reply

    This paragraph has **bold**, `inline code`, and a [web link](https://example.com) inside running text that wraps.

    - first item
    - second item with `inline code`
    - third item that wraps onto a second line because it is long enough to exceed the column width of the assistant body

    > A quote with enough text to wrap across a couple of lines in the narrow column.

    ```swift
    struct Example {
        let value: Int
    }
    ```

    | Name | Value | Note |
    | --- | --- | --- |
    | alpha | 1 | first |
    | beta | 2 | second |
    | gamma | 3 | third |

    Closing paragraph after the table.
    """

    static let tableOnly = """
    | Name | Value | Note |
    | --- | --- | --- |
    | alpha | 1 | first |
    | beta | 2 | second |
    | gamma | 3 | third |
    """

    static let codeOnly = """
    ```swift
    struct Example {
        let value: Int
    }
    ```
    """
}
#endif
