import Foundation

struct NativeAccount: Identifiable, Codable, Hashable {
    let id: Int
    var name: String
    var avatarURL: String?
}
