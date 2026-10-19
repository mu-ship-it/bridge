import Foundation
import WidgetKit

/// Keeps the widgets' snapshot in the App Group container in step with the Status screen.
@MainActor
enum WidgetPublisher {
    /// `reload`: ask WidgetKit to redraw now. Done after a job finishes and after a health sync;
    /// a plain poll only refreshes the file, so background polls do not spend the reload budget.
    static func publish(_ status: AppStatus, reload: Bool) {
        do {
            try SharedStore.save(snapshot(of: status))
        } catch {
            return
        }
        if reload { WidgetCenter.shared.reloadAllTimelines() }
    }

    static func snapshot(of status: AppStatus, now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(rows: rows(status.activity), agentLine: agentLine(status.activity),
                       lastPoll: status.lastPoll,
                       lastHealth: status.lastSync == nil ? nil : status.lastSyncMessage, generatedAt: now)
    }

    nonisolated static func rows(_ activity: [ActivityEntry]) -> [WidgetSnapshot.Row] {
        activity.prefix(WidgetSnapshot.rowLimit).map { entry in
            let status: WidgetSnapshot.Row.Status = switch entry.status {
            case .running: .running
            case .done: .done
            case .failed: .failed
            }
            return WidgetSnapshot.Row(id: entry.id, capability: entry.capability, note: entry.note, status: status,
                                      startedAt: entry.time, finishedAt: nil,
                                      summary: ActivitySummary.clip(entry.summary, 80))
        }
    }

    /// The text of the newest finished agent.say, as the feed row shows it.
    nonisolated static func agentLine(_ activity: [ActivityEntry]) -> String? {
        activity.first { $0.capability == "agent.say" && $0.status == .done && !$0.summary.isEmpty }?.summary
    }
}
