import Foundation

public enum OpenCodePluginRenderer {
    public static func render(relayPath: String) -> String {
        let relay = javaScriptStringLiteral(relayPath)
        return """
        // Perch integration
        // Sends only event type, session identifier, a bounded local task label, cwd,
        // the hosting terminal's device name, and timestamp.
        import { spawn, execFileSync } from "node:child_process"

        // The relay is spawned detached (so terminal signals never reach it),
        // which severs its controlling tty. This process is the one attached
        // to the terminal, so capture the device basename once here — stdin
        // is the hosting terminal — for the exact-tab return route.
        let controllingTTY = ""
        try {
          const name = execFileSync("/usr/bin/tty", { stdio: ["inherit", "pipe", "ignore"] })
            .toString().trim().replace("/dev/", "")
          if (/^ttys[0-9]+$/.test(name)) controllingTTY = name
        } catch {
          // Not attached to a terminal: the route is simply omitted.
        }

        export const PerchPlugin = async () => {
          const relay = \(relay)
          let activeSessionID = ""
          let lastLivenessSentAt = 0
          const sessionLabels = new Map()

          const send = (sessionID, eventName, taskLabel) => {
            if (typeof sessionID !== "string" || sessionID.length === 0) return
            activeSessionID = sessionID
            if (typeof taskLabel === "string" && taskLabel.trim().length > 0) {
              sessionLabels.set(sessionID, taskLabel.trim())
            }
            const payload = JSON.stringify({
              hook_event_name: eventName,
              session_id: sessionID,
              task_title: sessionLabels.get(sessionID),
              cwd: process.cwd(),
              tty: controllingTTY || undefined,
              timestamp: new Date().toISOString(),
            })
            try {
              const child = spawn("/bin/sh", [relay, "opencode", payload], {
                stdio: "ignore",
                detached: true,
              })
              child.unref()
            } catch {
              // Perch delivery is always best-effort and never blocks OpenCode.
            }
          }

          const resolveSessionID = (properties) => {
            return properties?.sessionID
              ?? properties?.info?.id
              ?? properties?.info?.sessionID
              ?? properties?.part?.sessionID
          }

          return {
            event: async ({ event }) => {
              const type = event?.type ?? ""
              const properties = event?.properties ?? {}
              const sessionID = resolveSessionID(properties) || activeSessionID
              const taskLabel = properties?.info?.title ?? properties?.title ?? sessionLabels.get(sessionID)

              // A long busy stretch emits no repeated session.status events, so
              // message progress doubles as a throttled, content-free liveness
              // signal that keeps the working session from expiring as stale.
              if (type === "message.updated" || type === "message.part.updated") {
                const now = Date.now()
                if (now - lastLivenessSentAt >= 30000) {
                  lastLivenessSentAt = now
                  await send(sessionID, "SessionStatusBusy", taskLabel)
                }
                return
              }
              if (type === "permission.asked" || type === "question.asked") {
                await send(sessionID, "PermissionAsked", taskLabel)
                return
              }
              if (type === "permission.replied" || type === "question.replied" || type === "question.rejected") {
                await send(sessionID, "PermissionReplied", taskLabel)
                return
              }
              if (type === "session.idle") {
                await send(sessionID, "SessionIdle", taskLabel)
                return
              }
              if (type === "session.deleted") {
                await send(sessionID, "SessionDeleted", taskLabel)
                return
              }
              if (type === "session.error") {
                await send(sessionID, "SessionError", taskLabel)
                return
              }
              if (type === "session.status") {
                const status = properties.status
                const statusType = typeof status === "string" ? status : status?.type
                await send(sessionID, statusType === "idle" ? "SessionStatusIdle" : "SessionStatusBusy", taskLabel)
              }
            },
          }
        }
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
