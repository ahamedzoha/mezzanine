#if DEBUG
import Foundation

/// Spike S2: one real library item per codec family on the owner's server,
/// picked by a read-only query of the Plex DB (2026-11-14). Rating keys are
/// stable unless an item is deleted and re-added.
struct LabMatrixEntry: Identifiable, Hashable {
    let id: String
    let ratingKey: String
    let note: String
}

enum LabMatrix {
    static let entries: [LabMatrixEntry] = [
        .init(id: "mp4-h264-aac-stereo", ratingKey: "542", note: "MP4 · H.264 1080p · AAC 2.0 — AVPlayer's home turf"),
        .init(id: "mkv-hevc-aac51-vobsub", ratingKey: "54", note: "MKV · HEVC · AAC 5.1 · VobSub"),
        .init(id: "eac3-51", ratingKey: "42", note: "MKV · H.264 · E-AC-3 5.1"),
        .init(id: "ac3-51", ratingKey: "2", note: "MKV · HEVC · AC-3 5.1"),
        .init(id: "opus-51-av1", ratingKey: "3405", note: "MKV · AV1 1080p · Opus 5.1"),
        .init(id: "dts-51-pgs", ratingKey: "380", note: "MKV · H.264 · DTS 5.1 · PGS"),
        .init(id: "truehd-71", ratingKey: "13235", note: "MKV · H.264 · TrueHD 7.1"),
        .init(id: "avi-mpeg4", ratingKey: "4585", note: "AVI · MPEG-4 Part 2 · MP3"),
        .init(id: "ass-subs", ratingKey: "1", note: "MKV · HEVC · AAC 5.1 · ASS"),
        .init(id: "hdr10", ratingKey: "446", note: "MKV · HEVC 2160p HDR10 · AC-3 5.1"),
        .init(id: "dv-p10-av1", ratingKey: "6265", note: "MKV · AV1 2160p Dolby Vision P10 · Opus 7.1"),
        .init(id: "episode-with-intro", ratingKey: "6458", note: "Episode with an intro marker"),
    ]
}
#endif
