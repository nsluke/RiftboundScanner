import SwiftUI

/// The iOS-only presentation modifiers the shared screens use, spelled once so
/// every screen compiles for both the iPhone and the Mac. On the Mac each one
/// is a no-op (a window has no inline-title mode, no on-screen keyboard and no
/// tinted navigation bar) or the closest native equivalent.
extension View {
    /// The compact title a pushed screen or a sheet uses on the iPhone.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Light bar text over the app's dark ground.
    func darkNavigationBar() -> some View {
        #if os(iOS)
        toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Hides the iPhone's navigation bar on a screen that draws its own
    /// controls over the camera. The Mac keeps its window toolbar.
    func hiddenNavigationBar() -> some View {
        #if os(iOS)
        toolbarVisibility(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Keyboard, capitalisation and autocorrection for one kind of field.
    func textEntry(_ kind: TextEntryKind) -> some View {
        #if os(iOS)
        switch kind {
        case .url:
            AnyView(keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled())
        case .verbatim:
            AnyView(textInputAutocapitalization(.never).autocorrectionDisabled())
        case .code:
            AnyView(textInputAutocapitalization(.characters).autocorrectionDisabled())
        case .decimal:
            AnyView(keyboardType(.decimalPad))
        case .number:
            AnyView(keyboardType(.numberPad))
        }
        #else
        switch kind {
        case .url, .verbatim, .code:
            AnyView(autocorrectionDisabled())
        case .decimal, .number:
            AnyView(self)
        }
        #endif
    }

    /// A picker that drills into its own list on the iPhone; a pop-up menu on the Mac.
    func drillDownPickerStyle() -> some View {
        #if os(iOS)
        pickerStyle(.navigationLink)
        #else
        pickerStyle(.menu)
        #endif
    }

    /// Room for a sheet's form on the Mac, where a sheet otherwise shrinks to
    /// its content's minimum; the iPhone's sheets fill the screen.
    func sheetSizing(minWidth: CGFloat = 480, minHeight: CGFloat = 560) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: minWidth * 1.2, minHeight: minHeight, idealHeight: minHeight * 1.2)
        #else
        self
        #endif
    }

    /// The screen's main action: filled in `tint` with dark text. On the Mac
    /// `.borderedProminent` turns grey while the window is inactive, which
    /// left the dark label unreadable, so the Mac draws its own fill.
    func prominentAction(_ tint: Color) -> some View {
        #if os(macOS)
        buttonStyle(FilledActionButtonStyle(tint: tint))
        #else
        buttonStyle(.borderedProminent)
            .tint(tint)
            .foregroundStyle(Theme.ground)
        #endif
    }
}

#if os(macOS)
/// A filled button that looks the same in a key and an inactive window.
private struct FilledActionButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(controlSize == .large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(Theme.ground)
            .padding(.horizontal, controlSize == .large ? 16 : 12)
            .frame(minHeight: controlSize == .large ? 32 : 24)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
#endif

/// What a text field holds, which decides its keyboard and corrections.
enum TextEntryKind {
    /// A server address: URL keyboard, no capitals, no corrections.
    case url
    /// A token or name typed exactly: no capitals, no corrections.
    case verbatim
    /// A printed card code such as `OGN-066`: capitals, no corrections.
    case code
    /// A price.
    case decimal
    /// A collector number.
    case number
}
