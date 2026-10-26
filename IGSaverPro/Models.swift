import Foundation

struct SessionStatus: Codable {
    let logged_in: Bool
    let user_id: String?
    let username: String?
    let session_file_exists: Bool
}

struct LoginPayload: Codable {
    var username: String?
    var password: String?
    var verification_code: String?
    var sessionid: String?
}

struct LoginResponse: Codable {
    let status: String?
    let username: String?
    let message: String?
    let detail: String?
}

struct SearchUser: Codable, Identifiable {
    let pk: String
    let username: String
    let full_name: String
    let profile_pic_url: String
    let is_private: Bool
    let is_verified: Bool
    let has_stories: Bool
    let following: Bool

    var id: String { pk + "_" + username }
}

struct SearchResponse: Codable {
    let status: String
    let count: Int
    let users: [SearchUser]
}

struct StoryItem: Codable, Identifiable {
    var pk: String?
    let media_type: String
    let url: String
    var thumbnail: String?
    var taken_at: String?
    let filename: String

    var id: String { filename + "_" + url }
}

struct HighlightTrayItem: Codable, Identifiable {
    let pk: String
    let title: String
    let cover_url: String
    let media_count: Int

    var id: String { pk }
}

struct PostItem: Codable, Identifiable {
    let pk: String
    let code: String
    let media_type: String
    let thumbnail: String
    let caption: String
    let like_count: Int
    let comment_count: Int
    let taken_at: String
    let items: [StoryItem]

    var id: String { pk }
}

struct ProfileUser: Codable {
    let pk: String
    let username: String
    let full_name: String
    let biography: String
    let profile_pic_hd: String
    let is_private: Bool
    let is_verified: Bool
    let media_count: Int
    let follower_count: Int
    let following_count: Int
}

struct ResolveResponse: Codable {
    let status: String
    let type: String
    let user: ProfileUser?
    let stories: [StoryItem]?
    let highlights: [HighlightTrayItem]?
    let posts: [PostItem]?
    let next_cursor: String?
    let username: String?
    let count: Int?
    let items: [StoryItem]?
}

struct HighlightDetailResponse: Codable {
    let status: String
    let pk: String
    let title: String
    let username: String
    let count: Int
    let items: [StoryItem]
}

struct MorePostsResponse: Codable {
    let status: String
    let posts: [PostItem]
    let next_cursor: String
}

struct SavedAccount: Codable, Identifiable, Equatable {
    let username: String
    let full_name: String
    let profile_pic: String

    var id: String { username.lowercased() }
}
