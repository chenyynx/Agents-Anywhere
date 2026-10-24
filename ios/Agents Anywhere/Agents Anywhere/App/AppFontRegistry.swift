import CoreText
import Foundation

@MainActor
enum AppFontRegistry {
    private static var registered = false

    /// The product's brand face. Missing is a build error.
    private static let requiredFonts = ["caveat_wght"]

    /// The official Code page's faces, extracted from the official IPA's
    /// `ClaudeFonts_ClaudeFonts.bundle`. A missing optional face is not fatal:
    /// `MarkdownFontFactory` falls back to the system face, so a partial
    /// bundle still runs.
    private static let optionalFonts = [
        "AnthropicSansMobileVariable-TextRegular",
        "AnthropicSansMobileVariable-TextRegularItalic",
        "AnthropicSerifMobileVariable-TextRegular",
        "AnthropicSerifMobileVariable-TextRegularItalic",
        "JetBrainsMono-Regular",
    ]

    /// Registers the bundled fonts with Core Text for the current process.
    static func registerBundledFonts() {
        guard !registered else { return }
        for name in requiredFonts {
            guard let fontURL = Bundle.main.url(
                forResource: name,
                withExtension: "ttf"
            ) else {
                preconditionFailure("Bundled font \(name) is missing")
            }
            register(fontURL, required: true, name: name)
        }
        for name in optionalFonts {
            guard let fontURL = Bundle.main.url(
                forResource: name,
                withExtension: "ttf"
            ) else { continue }
            register(fontURL, required: false, name: name)
        }
        registered = true
    }

    private static func register(_ fontURL: URL, required: Bool, name: String) {
        var registrationError: Unmanaged<CFError>?
        let registrationSucceeded = CTFontManagerRegisterFontsForURL(
            fontURL as CFURL,
            .process,
            &registrationError
        )
        if registrationSucceeded { return }
        let error = registrationError?.takeRetainedValue() as Error? as NSError?
        let fontWasAlreadyRegistered = error?.domain == kCTFontManagerErrorDomain as String
            && error?.code == CTFontManagerError.alreadyRegistered.rawValue
        if fontWasAlreadyRegistered { return }
        if required {
            let description = error?.localizedDescription ?? "Unknown Core Text error"
            preconditionFailure("Unable to register bundled font \(name): \(description)")
        }
    }
}
