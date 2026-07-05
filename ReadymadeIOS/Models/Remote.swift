import Foundation

struct Remote: Codable, Identifiable {
    let port: Int
    let url: String
    let name: String

    var id: String {
        "\(name)-\(url)-\(port)"
    }
}
