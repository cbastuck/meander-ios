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
        let group = DispatchGroup()

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(urlType) {
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
            self?.presentPicker(url: pendingURL, text: pendingText)
        }
    }

    // ── Picker UI ─────────────────────────────────────────────────────────────

    private func presentPicker(url: String?, text: String?) {
        // Nothing usable was shared — just close without bothering the user.
        guard url != nil || (text?.isEmpty == false) else {
            NSLog("[ReadymadeShare] nothing usable shared; closing")
            complete()
            return
        }

        let picker = SharePickerView(
            preview: url ?? text ?? "Shared content",
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

    // ── Completion ────────────────────────────────────────────────────────────

    private func save(url: String?, text: String?, boardName: String?) {
        let item = SharedItem(url: url, title: nil, text: text, boardName: boardName)
        do {
            let id = try ShareInbox.write(item)
            NSLog("[ReadymadeShare] wrote inbox item %@ (board=%@)", id, boardName ?? "none")
        } catch {
            NSLog("[ReadymadeShare] inbox write FAILED: %@", error.localizedDescription)
        }
        complete()
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
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
