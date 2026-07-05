import Foundation

@MainActor
final class BoardListViewModel: ObservableObject {
    @Published var boards: [String] = []
    @Published var remotes: [Remote] = []
    @Published var selectedBoardName: String = ""
    @Published var boardJSON: String = "{}"
    @Published var saveName: String = "Idea"
    @Published var statusMessage: String = ""
    @Published var isLoading: Bool = false

    private var client: MeanderAPIClient

    init(baseURL: String) {
        if let configuredClient = try? MeanderAPIClient(baseURLString: baseURL) {
            client = configuredClient
            statusMessage = "Connected to \(baseURL)"
            return
        }

        client = try! MeanderAPIClient(baseURLString: "http://127.0.0.1:5556")
        statusMessage = "Invalid startup URL, using fallback http://127.0.0.1:5556"
    }

    func updateBaseURL(_ baseURL: String) {
        do {
            try client.updateBaseURL(baseURL)
            statusMessage = "Switched API base URL to \(baseURL)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let fetchedBoards = client.fetchBoards()
            async let fetchedRemotes = fetchRemotesOrEmpty()
            boards = try await fetchedBoards.sorted()
            remotes = await fetchedRemotes
            if selectedBoardName.isEmpty, let first = boards.first {
                selectedBoardName = first
            }
            statusMessage = "Loaded \(boards.count) board(s)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadSelectedBoard() async {
        guard !selectedBoardName.isEmpty else {
            statusMessage = "Select a board to load."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            boardJSON = try await client.loadBoard(named: selectedBoardName)
            saveName = selectedBoardName
            statusMessage = "Loaded board '\(selectedBoardName)'."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveCurrentBoard() async {
        let trimmedName = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Board name cannot be empty."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let draft = BoardDraft(name: trimmedName, json: boardJSON)
            try await client.saveBoard(draft)
            selectedBoardName = trimmedName
            statusMessage = "Saved board '\(trimmedName)'."
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteSelectedBoard() async {
        guard !selectedBoardName.isEmpty else {
            statusMessage = "Select a board to delete."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await client.deleteBoard(named: selectedBoardName)
            statusMessage = "Deleted board '\(selectedBoardName)'."
            selectedBoardName = ""
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func fetchRemotesOrEmpty() async -> [Remote] {
        do {
            return try await client.fetchRemotes()
        } catch {
            return []
        }
    }
}
