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

    /// A Plex universal-transcode HLS stream: the fallback when direct play fails, and the
    /// quality caps for slow remote links. Subtitles are left out (Mezzanine draws its own;
    /// sidecar files still load). Start position is the player's seek, not `offset`, so the
    /// stream's clock matches the film's.
    public func transcode(ratingKey: String, _ options: TranscodeOptions) -> URL? {
        transcodeURL("start.m3u8", ratingKey: ratingKey, options)
    }

    /// The decision for the same session; Plex answers 400 to `start.m3u8` until it has made one.
    public func transcodeDecision(ratingKey: String, _ options: TranscodeOptions) -> URL? {
        transcodeURL("decision", ratingKey: ratingKey, options)
    }

    /// The same stream for a device that can't send headers (a TV casting from Mezzanine): the
    /// short-lived `token` and the sender's identity ride in the URL, and the target profile is
    /// what a Cast receiver plays.
    public func castTranscode(_ endpoint: String, ratingKey: String, _ options: TranscodeOptions,
                              token: String, identity: [String: String], compatible: Bool = false) -> URL? {
        transcodeURL(endpoint, ratingKey: ratingKey, options, profileExtra: TranscodeOptions.castProfileExtra(compatible: compatible),
                     extra: identity.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } + [("X-Plex-Token", token)])
    }

    /// An image for a device that can't send headers, with the short-lived token in the URL.
    public func castImage(_ path: String, width: Int, height: Int, token: String) -> URL? {
        guard let url = photo(path, width: width, height: height), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "X-Plex-Token", value: token)]
        return c.url
    }

    private func transcodeURL(_ endpoint: String, ratingKey: String, _ options: TranscodeOptions,
                              profileExtra: String = TranscodeOptions.profileExtra, extra: [(String, String)] = []) -> URL? {
        var c = URLComponents(url: baseURL.appending(path: "video/:/transcode/universal/\(endpoint)"), resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = c.percentEncodedPath.replacingOccurrences(of: "%3A", with: ":")
        var items: [(String, String)] = [
            ("hasMDE", "1"),
            ("path", "/library/metadata/\(ratingKey)"),
            ("mediaIndex", String(options.mediaIndex)),
            ("partIndex", "0"),
            ("protocol", "hls"),
            ("fastSeek", "1"),
            ("directPlay", "0"),
            ("directStream", options.directStream ? "1" : "0"),
            ("directStreamAudio", options.directStream ? "1" : "0"),
            ("subtitles", "none"),
            ("copyts", "1"),
            ("mediaBufferSize", "102400"),
            ("autoAdjustQuality", "0"),
            ("location", options.isLocal ? "lan" : "wan"),
            ("session", options.session),
            ("X-Plex-Session-Identifier", options.session),
            // Plex has no transcode profile for platform "macOS" (it answers 400); the Generic
            // profile plus Mezzanine's own target declaration is accepted.
            ("X-Plex-Client-Profile-Name", "Generic"),
            ("X-Plex-Client-Profile-Extra", profileExtra),
        ] + extra
        if let kbps = options.maxVideoBitrate {
            items += [("videoQuality", "100"), ("maxVideoBitrate", String(kbps))]
        } else {
            items += [("videoQuality", "100")]
        }
        if let resolution = options.videoResolution { items.append(("videoResolution", resolution)) }
        c.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.0, value: $0.1.addingPercentEncoding(withAllowedCharacters: .plexQueryAllowed))
        }
        return c.url
    }

    /// Ends a transcode session (on close, or when switching back to direct play).
    public func stopTranscode(session: String) -> URL? {
        var c = URLComponents(url: baseURL.appending(path: "video/:/transcode/universal/stop"), resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = c.percentEncodedPath.replacingOccurrences(of: "%3A", with: ":")
        c.queryItems = [URLQueryItem(name: "session", value: session)]
        return c.url
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

/// How to ask Plex for a converted stream.
public struct TranscodeOptions: Sendable, Equatable {
    /// Copy the video and audio when they fit (a remux); false re-encodes.
    public var directStream: Bool
    /// kbps cap; nil keeps the original quality.
    public var maxVideoBitrate: Int?
    /// "1920x1080"; nil keeps the original size.
    public var videoResolution: String?
    public var mediaIndex: Int
    public var isLocal: Bool
    public var session: String

    public init(directStream: Bool, maxVideoBitrate: Int? = nil, videoResolution: String? = nil,
                mediaIndex: Int = 0, isLocal: Bool = true, session: String = UUID().uuidString) {
        self.directStream = directStream
        self.maxVideoBitrate = maxVideoBitrate
        self.videoResolution = videoResolution
        self.mediaIndex = mediaIndex
        self.isLocal = isLocal
        self.session = session
    }

    /// What a Cast receiver plays from Plex: HLS in MPEG-TS with H.264 or HEVC video and AAC,
    /// AC-3 or E-AC-3 sound (copied when the file already has them).
    /// `compatible`: H.264 and stereo AAC only (what every Cast device plays).
    public static func castProfileExtra(compatible: Bool) -> String {
        compatible
            ? "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)"
                + "+add-limitation(scope=videoAudioCodec&scopeName=aac&type=upperBound&name=audio.channels&value=2)"
            : "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3&replace=true)"
    }

    /// What Mezzanine's engine plays: HLS in MPEG-TS with H.264/HEVC and AAC/AC-3/E-AC-3.
    public static let profileExtra =
        "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3&replace=true)"
}
