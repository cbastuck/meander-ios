import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share-sheet entry point for "Share → Readymade". It runs in its own
/// process, so it cannot touch the host app's WebView or board list. iOS also
/// forbids a share extension from foregrounding its host app, so — like the
/// messenger apps — the whole *choice* happens here: a native picker lists the
/// boards (mirrored into the App Group by the app), the user picks one, and the
/// envelope is stored tagged with that board. The board itself runs the next
/// time Readymade opens; the picker says so explicitly.
final class ShareViewController: UIViewController {
    private let urlType = UTType.url.identifier
    private let plainTextType = UTType.plainText.identifier
    private var didStart = false

    /// A binary payload staged in the extension's tmp dir. The file from
    /// `loadFileRepresentation` only lives for the duration of its completion
    /// handler, so it is copied here first; on save it moves into the App Group
    /// keyed by the item id.
    private struct StagedFile {
        let url: URL
        let meta: SharedFile
    }
    private var stagedFile: StagedFile?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // viewDidAppear can fire more than once; only run the extraction once.
        guard !didStart else { return }
        didStart = true
        loadSharedContent()
    }

    // ── Content extraction ────────────────────────────────────────────────────

    private func loadSharedContent() {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        // The content text the user may have typed in the share sheet composer,
        // and/or a title carried by the input item.
        let inputItems = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let composedText = inputItems.compactMap { $0.attributedContentText?.string }
            .first(where: { !$0.isEmpty })

        NSLog("[ReadymadeShare] loadSharedContent: %d attachment(s)", attachments.count)

        var pendingURL: String?
        var pendingText: String? = composedText
        var fileTooLarge = false
        let group = DispatchGroup()

        for provider in attachments {
            // Order matters: file-backed attachments first. A shared file's URL
            // conforms to public.url too, so testing the web-URL branch first
            // would swallow Files-app shares as bogus "links".
            if let fileType = fileTypeIdentifier(for: provider) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: fileType) { [weak self] tempURL, _ in
                    // tempURL dies when this handler returns — stage a copy now.
                    if let tempURL, let self {
                        let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]))?
                            .fileSize ?? 0
                        if size > ShareInbox.maxFilePayloadBytes {
                            fileTooLarge = true
                        } else {
                            self.stagedFile = self.stage(tempURL: tempURL, size: size)
                        }
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(urlType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { item, _ in
                    if let url = item as? URL {
                        pendingURL = url.absoluteString
                    } else if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                        pendingURL = s
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(plainTextType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: plainTextType, options: nil) { item, _ in
                    if let text = item as? String {
                        pendingText = pendingText ?? text
                    } else if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                        pendingText = pendingText ?? s
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if fileTooLarge && self.stagedFile == nil {
                self.presentTooLarge()
            } else {
                self.presentPicker(url: pendingURL, text: pendingText)
            }
        }
    }

    /// The concrete type identifier to load a file-backed attachment with, or
    /// nil when the attachment is not a file (web link, plain text). Images and
    /// movies conform to public.data; a Files-app share is a public.file-url.
    private func fileTypeIdentifier(for provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return UTType.image.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return UTType.movie.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return UTType.fileURL.identifier
        }
        // Generic data (PDFs and other documents), but not bare links/text —
        // those are handled by the dedicated URL/text branches.
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
           !provider.hasItemConformingToTypeIdentifier(urlType),
           !provider.hasItemConformingToTypeIdentifier(plainTextType) {
            return provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        }
        return nil
    }

    /// Copies the short-lived temp file into our own tmp dir and derives the
    /// name/mime metadata from it.
    private func stage(tempURL: URL, size: Int) -> StagedFile? {
        let name = tempURL.lastPathComponent
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("readymade-share-\(UUID().uuidString)")
            .appendingPathExtension(tempURL.pathExtension)
        do {
            try FileManager.default.copyItem(at: tempURL, to: staging)
        } catch {
            NSLog("[ReadymadeShare] staging copy FAILED: %@", error.localizedDescription)
            return nil
        }
        let mimeType = UTType(filenameExtension: tempURL.pathExtension)?
            .preferredMIMEType ?? "application/octet-stream"
        return StagedFile(
            url: staging,
            meta: SharedFile(name: name, mimeType: mimeType, size: size)
        )
    }

    // ── Picker UI ─────────────────────────────────────────────────────────────

    private func presentPicker(url: String?, text: String?) {
        // Nothing usable was shared — just close without bothering the user.
        guard stagedFile != nil || url != nil || (text?.isEmpty == false) else {
            NSLog("[ReadymadeShare] nothing usable shared; closing")
            complete()
            return
        }

        let preview: String
        if let staged = stagedFile {
            preview = "\(staged.meta.name) (\(formatBytes(staged.meta.size)))"
        } else {
            preview = url ?? text ?? "Shared content"
        }

        let picker = SharePickerView(
            preview: preview,
            boards: ShareInbox.readBoardsMirror(),
            onPick: { [weak self] boardName in
                self?.save(url: url, text: text, boardName: boardName)
            },
            onSaveWithoutBoard: { [weak self] in
                // No board chosen (e.g. none exist yet): store untagged; the
                // in-app picker will ask when Readymade next opens.
                self?.save(url: url, text: text, boardName: nil)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        let host = UIHostingController(rootView: picker)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// Shown when the shared file exceeds the payload cap.
    private func presentTooLarge() {
        let notice = ShareNoticeView(
            title: "File too large",
            message: "Readymade accepts shared files up to \(formatBytes(ShareInbox.maxFilePayloadBytes)).",
            onDismiss: { [weak self] in self?.cancel() }
        )
        let host = UIHostingController(rootView: notice)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    // ── Completion ────────────────────────────────────────────────────────────

    private func save(url: String?, text: String?, boardName: String?) {
        let item = SharedItem(
            url: url,
            title: nil,
            text: text,
            boardName: boardName,
            file: stagedFile?.meta
        )
        do {
            if let staged = stagedFile {
                try ShareInbox.storeFilePayload(from: staged.url, id: item.id)
            }
            let id = try ShareInbox.write(item)
            NSLog(
                "[ReadymadeShare] wrote inbox item %@ (board=%@, file=%@)",
                id, boardName ?? "none", stagedFile?.meta.name ?? "none"
            )
        } catch {
            NSLog("[ReadymadeShare] inbox write FAILED: %@", error.localizedDescription)
            ShareInbox.removeFilePayload(id: item.id)
        }
        complete()
    }

    private func complete() {
        cleanupStaging()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        cleanupStaging()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func cleanupStaging() {
        if let staged = stagedFile {
            try? FileManager.default.removeItem(at: staged.url)
            stagedFile = nil
        }
    }
}

private func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// ── SwiftUI picker sheet ──────────────────────────────────────────────────────

/// Bottom card mirroring the in-app picker's look: shared-content preview, the
/// board list, and the note that the board runs on next app open.
private struct SharePickerView: View {
    let preview: String
    let boards: [String]
    let onPick: (String) -> Void
    let onSaveWithoutBoard: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dimmed backdrop; tapping it cancels, like a sheet.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 38, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Send to a board")
                        .font(.headline)
                    Text(preview)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                Divider()

                if boards.isEmpty {
                    VStack(spacing: 12) {
                        Text("No boards yet")
                            .font(.body)
                        Text("You can still save the share — Readymade will ask for a board when you open it.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Save for later", action: onSaveWithoutBoard)
                            .font(.body.weight(.semibold))
                    }
                    .padding(.vertical, 24)
                    .padding(.horizontal, 20)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(boards, id: \.self) { name in
                                Button {
                                    onPick(name)
                                } label: {
                                    Text(name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 15)
                                }
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                    .frame(maxHeight: 300)

                    // Same untagged save as the empty state: Readymade's in-app
                    // picker asks for the board on next open.
                    Button(action: onSaveWithoutBoard) {
                        Text("Decide later in Readymade")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 15)
                    }
                }

                // The one thing iOS won't let us do is open the app from here —
                // say so instead of looking broken.
                Text("The board runs the next time you open Readymade.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
            .padding(.bottom, 12)
            .background(
                RoundedCorners(radius: 18)
                    .fill(Color(UIColor.systemBackground))
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}

/// Minimal bottom card for a one-line notice (e.g. file exceeds the size cap).
private struct ShareNoticeView: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .padding(.top, 24)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button(action: onDismiss) {
                    Text("OK")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(
                RoundedCorners(radius: 18)
                    .fill(Color(UIColor.systemBackground))
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}

/// Top-only rounded corners for the bottom card.
private struct RoundedCorners: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: [.topLeft, .topRight],
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath
        )
    }
}
