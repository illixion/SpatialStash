/*
 Hypnos - Platform Pasteboard

 macOS-only. The two "Copy" actions in this app (`MediaDetailSheet`,
 `DepthPipelineSpikeSection`) are already `#if !os(tvOS)` — tvOS has no
 pasteboard — and read `UIPasteboard.general.string = value`. Rather than
 touch those two call sites, this gives macOS its own `UIPasteboard.general`
 stand-in with the same settable-`.string` shape, backed by `NSPasteboard`.
 */

#if os(macOS)
import AppKit

enum UIPasteboard {
    static let general = PasteboardProxy()

    struct PasteboardProxy {
        var string: String? {
            get { NSPasteboard.general.string(forType: .string) }
            nonmutating set {
                NSPasteboard.general.clearContents()
                if let newValue {
                    NSPasteboard.general.setString(newValue, forType: .string)
                }
            }
        }
    }
}
#endif
