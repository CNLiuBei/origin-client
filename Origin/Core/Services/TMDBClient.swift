import Foundation

/// TMDB 补充信息：Logo、预告片、标语、演员头像等
struct TMDBEnrichment: Sendable {
    var logoURL: URL?
    var backdropURL: URL?
    var trailerURL: URL?
    var tagline: String?
    var overview: String?
    var voteAverage: Double?
    var cast: [MediaPerson] = []
    var tmdbURL: URL?
}

final class TMDBClient {
    private let http = HTTPClient(timeout: 15)
    private let base = URL(string: "https://api.themoviedb.org/3")!
    private var cache: [String: TMDBEnrichment] = [:]
    var token: String

    init(token: String) {
        self.token = token
    }

    static var bundledToken: String {
        (Bundle.main.object(forInfoDictionaryKey: "TMDBReadToken") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    var isConfigured: Bool { !token.isEmpty }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    }

    private var language: String {
        let code = Locale.preferredLanguages.first ?? "zh-CN"
        return code.hasPrefix("zh") ? "zh-CN" : code
    }

    func validate() async -> Bool {
        (try? await http.data(base.appending(path: "/authentication", query: [:]), headers: headers)) != nil
    }

    func enrichment(for item: MediaItem) async -> TMDBEnrichment? {
        guard isConfigured else { return nil }
        let isTV = item.kind == .series || item.kind == .season || item.kind == .episode
        let cacheKey = "\(isTV)-\(item.seriesID ?? item.id)-\(item.serverID)"
        if let cached = cache[cacheKey] { return cached }

        var tmdbID = item.kind == .movie || item.kind == .series ? item.tmdbID : nil
        if tmdbID == nil {
            tmdbID = await searchID(query: item.kind == .episode || item.kind == .season ? (item.seriesName ?? item.name) : item.name,
                                    year: item.kind == .movie || item.kind == .series ? item.year : nil, isTV: isTV)
        }
        guard let tmdbID else { return nil }

        let path = isTV ? "/tv/\(tmdbID)" : "/movie/\(tmdbID)"
        let url = base.appending(path: path, query: [
            "language": language,
            "append_to_response": "videos,images,credits",
            "include_image_language": "zh,en,null",
            "include_video_language": "zh,en",
        ])
        guard let details = try? await http.decode(Details.self, from: url, headers: headers, decoder: .snakeCase) else { return nil }

        var result = TMDBEnrichment()
        let logos = details.images?.logos ?? []
        let logo = logos.first { $0.iso6391 == "zh" } ?? logos.first { $0.iso6391 == "en" } ?? logos.first
        result.logoURL = logo.flatMap { Self.image($0.filePath, size: "w500") }
        result.backdropURL = details.backdropPath.flatMap { Self.image($0, size: "w1280") }
        let videos = (details.videos?.results ?? []).filter { $0.site == "YouTube" }
        let trailer = videos.first { $0.type == "Trailer" } ?? videos.first { $0.type == "Teaser" } ?? videos.first
        result.trailerURL = trailer.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0.key)") }
        result.tagline = details.tagline.flatMap { $0.isEmpty ? nil : $0 }
        result.overview = details.overview.flatMap { $0.isEmpty ? nil : $0 }
        result.voteAverage = details.voteAverage
        result.cast = (details.credits?.cast ?? []).prefix(20).map {
            MediaPerson(id: "tmdb-\($0.id)", name: $0.name, role: $0.character, imageURL: $0.profilePath.flatMap { Self.image($0, size: "w185") })
        }
        result.tmdbURL = URL(string: "https://www.themoviedb.org/\(isTV ? "tv" : "movie")/\(tmdbID)")
        cache[cacheKey] = result
        return result
    }

    private func searchID(query: String, year: Int?, isTV: Bool) async -> String? {
        let url = base.appending(path: isTV ? "/search/tv" : "/search/movie", query: [
            "query": query,
            "language": language,
            isTV ? "first_air_date_year" : "year": year.map(String.init),
        ])
        struct Search: Decodable { struct Hit: Decodable { let id: Int }; let results: [Hit] }
        return (try? await http.decode(Search.self, from: url, headers: headers, decoder: .snakeCase))?.results.first.map { "\($0.id)" }
    }

    static func image(_ path: String, size: String) -> URL? {
        URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    private struct Details: Decodable {
        struct Images: Decodable { let logos: [Image]? }
        struct Image: Decodable { let filePath: String; let iso6391: String? }
        struct Videos: Decodable { let results: [Video] }
        struct Video: Decodable { let key: String; let site: String; let type: String }
        struct Credits: Decodable { let cast: [Cast] }
        struct Cast: Decodable { let id: Int; let name: String; let character: String?; let profilePath: String? }

        let tagline: String?
        let overview: String?
        let voteAverage: Double?
        let backdropPath: String?
        let images: Images?
        let videos: Videos?
        let credits: Credits?
    }
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
