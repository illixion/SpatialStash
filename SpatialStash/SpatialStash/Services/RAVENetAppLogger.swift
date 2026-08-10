/*
 Spatial Stash - RAVENet logging bridge

 RAVENet doesn't know about this app's logger, so it takes a sink. This
 forwards its transport diagnostics into the same `AppLogger.remoteViewer`
 category they used to be written to directly, so the in-app Console keeps
 showing them unchanged.
 */

import Foundation
import RAVENet
import os

/// Forwards `RAVENet` transport logging into `AppLogger.remoteViewer`.
///
/// Debug-level lines are routed through `AppLogger.effectiveDebugLevel` so they
/// obey the app's existing developer-toggle gating rather than always emitting.
struct RAVENetAppLogger: RAVENetLogger {
    func log(_ level: RAVENetLogLevel, _ message: String) {
        switch level {
        case .debug:
            AppLogger.remoteViewer.log(level: AppLogger.effectiveDebugLevel, "WebSocket \(message, privacy: .public)")
        case .info:
            AppLogger.remoteViewer.info("WebSocket \(message, privacy: .public)")
        case .warning:
            AppLogger.remoteViewer.warning("WebSocket \(message, privacy: .public)")
        case .error:
            AppLogger.remoteViewer.error("WebSocket \(message, privacy: .public)")
        }
    }
}
