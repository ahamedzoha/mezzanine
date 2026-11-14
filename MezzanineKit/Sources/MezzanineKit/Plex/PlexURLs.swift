import Foundation

/// Builds URLs for media and artwork on one server.
///
/// Mezzanine sends the token as an `X-Plex-Token` header wherever it can
/// (API calls, the playback engine's `httpHeaders`, the image pipeline), so
/// these URLs carry no token by default. `tokenized` exists for the rare
/// consumer that can't send headers; `redacted` strips tokens from anything
/// that might be logged.
public struct PlexURLs: Sendable {
    public let baseURL: URL
    let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// The original file of a part, for direct play or download.
    /// `key` is the part's `key` (`/library/parts/{id}/{ts}/file.mkv`).
    public func part(key: String) -> URL? {
        URL(string: key, relativeTo: baseURL)?.absoluteURL
    }

    /// A server-resized image. Asking for the exact pixel size of the slot
    /// keeps posters sharp on Retina without shipping 2000-px originals.
    public func photo(_ path: String, width: Int, height: Int, blur: Int? = nil, upscale: Bool = true) -> URL? {
        var c = URLComponents(url: baseURL.appending(path: "photo/:/transcode"), resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = c.percentEncodedPath.replacingOccurrences(of: "%3A", with: ":")
        var items = [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: upscale ? "1" : "0"),
            URLQueryItem(name: "url", value: path),
        ]
        if let blur { items.append(URLQueryItem(name: "blur", value: String(blur))) }
        c.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: .plexQueryAllowed))
        }
        return c.url
    }

    /// An image at its original size (logos, which shouldn't be recompressed).
    public func asset(_ path: String) -> URL? {
        URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    /// BIF scrub thumbnails for a part.
    public func previewIndex(partID: Int) -> URL {
        baseURL.appending(path: "library/parts/\(partID)/indexes/sd")
    }

    /// An external subtitle stream (`/library/streams/{id}`), as a file.
    public func subtitle(streamKey: String, format: String? = nil) -> URL? {
        guard var c = URLComponents(string: baseURL.absoluteString + streamKey) else { return nil }
        if let format { c.queryItems = [URLQueryItem(name: "format", value: format)] }
        return c.url
    }

    /// Adds the token as a query item, for consumers that can't send headers.
    public func tokenized(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = c.queryItems ?? []
        items.removeAll { $0.name == "X-Plex-Token" }
        items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        c.queryItems = items
        return c.url ?? url
    }

    /// The URL with any token query value replaced, safe for logs.
    public static func redacted(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = c.queryItems else {
            return url.absoluteString
        }
        c.queryItems = items.map {
            $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame ? URLQueryItem(name: $0.name, value: "REDACTED") : $0
        }
        return c.url?.absoluteString ?? url.absoluteString
    }
}
