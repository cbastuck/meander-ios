import AppIntents
import Foundation

/// "Open Board": the action a person builds a Home Screen icon from in
/// Shortcuts, and what Siri and Spotlight run for a board's name.
struct OpenBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Board"
    static var description = IntentDescription("Opens a Readymade board.")
    static var openAppWhenRun = true

    @Parameter(title: "Board")
    var board: BoardEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$board)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.open(kind: board.kind, id: board.boardId)
        return .result()
    }
}

struct ReadymadeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenBoardIntent(),
            phrases: [
                "Open \(\.$board) in \(.applicationName)",
                "Open a board in \(.applicationName)",
            ]
        )
    }
}
