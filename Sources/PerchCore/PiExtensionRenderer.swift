import Foundation

public enum PiExtensionRenderer {
    public static func render(relayPath: String) -> String {
        let relay = javaScriptStringLiteral(relayPath)
        return """
        // Perch integration
        // Sends only event name, session identifier, cwd, the hosting terminal's
        // device name, and timestamp to the local Perch relay.
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

        export default function (pi) {
          let lastRunFailed = false
          let lastLivenessSentAt = 0
          const send = (ctx, eventName) => {
            const relay = \(relay)
            let sessionID = ""
            try {
              sessionID = ctx?.sessionManager?.getSessionId?.() ?? ""
            } catch {
              return
            }
            if (typeof sessionID !== "string" || sessionID.length === 0) return
            const payload = JSON.stringify({
              hook_event_name: eventName,
              session_id: sessionID,
              cwd: process.cwd(),
              tty: controllingTTY || undefined,
              timestamp: new Date().toISOString(),
            })
            try {
              const child = spawn("/bin/sh", [relay, "pi", payload], { stdio: "ignore", detached: true })
              child.unref()
            } catch {
              // Perch delivery is always best-effort and never blocks pi.
            }
          }

          // Long agent runs can stay inside one loop for many minutes. Turn and
          // tool boundaries are official liveness signals; throttle them so the
          // relay sees at most one working heartbeat every 30 seconds.
          const sendLiveness = (ctx, eventName) => {
            const now = Date.now()
            if (now - lastLivenessSentAt < 30000) return
            lastLivenessSentAt = now
            send(ctx, eventName)
          }

          pi.on("session_start", async (_event, ctx) => send(ctx, "SessionStart"))
          pi.on("agent_start", async (_event, ctx) => {
            lastRunFailed = false
            lastLivenessSentAt = Date.now()
            send(ctx, "AgentStart")
          })
          pi.on("turn_start", async (_event, ctx) => sendLiveness(ctx, "TurnStart"))
          pi.on("tool_execution_start", async (_event, ctx) => sendLiveness(ctx, "ToolExecutionStart"))
          pi.on("agent_end", async (event, _ctx) => {
            const messages = Array.isArray(event?.messages) ? event.messages : []
            const assistant = [...messages].reverse().find((message) => message?.role === "assistant")
            lastRunFailed = assistant?.stopReason === "error" || assistant?.stopReason === "aborted"
          })
          pi.on("agent_settled", async (_event, ctx) => {
            send(ctx, lastRunFailed ? "AgentFailed" : "AgentSettled")
            lastRunFailed = false
          })
          pi.on("session_shutdown", async (_event, ctx) => send(ctx, "SessionShutdown"))
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
