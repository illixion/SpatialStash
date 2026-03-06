/*
 Spatial Stash - Share Sheet Helper

 SwiftUI wrapper for UIActivityViewController on visionOS.
 Presented via SwiftUI's .sheet to ensure proper hand tracking input.
 */

import SwiftUI

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> ActivityHostController {
        ActivityHostController(activityItems: activityItems, isPresented: $isPresented)
    }

    func updateUIViewController(_ uiViewController: ActivityHostController, context: Context) {}
}

/// Container that presents UIActivityViewController in viewDidAppear,
/// ensuring the view is fully in the hierarchy before presentation.
class ActivityHostController: UIViewController {
    private let activityItems: [Any]
    private var isPresented: Binding<Bool>
    private var didPresent = false

    init(activityItems: [Any], isPresented: Binding<Bool>) {
        self.activityItems = activityItems
        self.isPresented = isPresented
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresent else { return }
        didPresent = true

        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            DispatchQueue.main.async {
                self?.isPresented.wrappedValue = false
            }
        }
        present(activityVC, animated: true)
    }
}

@MainActor
enum ShareSheetHelper {
    /// Prepare a shareable file URL with a human-readable name and correct extension.
    /// Copies/hardlinks the source file to a temp directory with the given name.
    static func prepareShareFile(from sourceURL: URL, title: String?, originalURL: URL) -> URL {
        let fileName: String

        if let title, !title.isEmpty {
            // Sanitize title for use as filename
            var sanitized = title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")

            // If the title already has an extension, use it as-is.
            // Otherwise, append the extension from the original URL if available.
            let titleExt = (sanitized as NSString).pathExtension
            if titleExt.isEmpty {
                let urlExt = originalURL.pathExtension
                if !urlExt.isEmpty {
                    sanitized = "\(sanitized).\(urlExt)"
                }
            }
            fileName = sanitized
        } else {
            // Fall back to the original URL's last path component
            fileName = originalURL.lastPathComponent
        }

        let shareDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShareItems", isDirectory: true)
        try? FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)

        let destURL = shareDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destURL)

        // Try hardlink first (no extra disk space), fall back to copy
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destURL)
        } catch {
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        }

        return destURL
    }
}
