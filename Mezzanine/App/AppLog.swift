import OSLog

/// The app's own log (Console, and Help ▸ Save Diagnostics Report…). Only what's safe to read is
/// public: never titles, names, addresses or tokens.
nonisolated enum AppLog {
    static let subsystem = "com.mezzanine.mac"
    static let session = Logger(subsystem: subsystem, category: "session")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let sound = Logger(subsystem: subsystem, category: "sound")
}
