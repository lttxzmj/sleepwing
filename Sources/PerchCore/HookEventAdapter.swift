import Foundation

public enum HookEventAdapterError: Error {
    case invalidJSON
}

public enum HookEventAdapter {
    public static func adapt(provider: AgentProvider, data: Data, receivedAt: Date = .now) throws -> AgentEvent {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookEventAdapterError.invalidJSON
        }
        let properties = object["properties"] as? [String: Any]
        let info = properties?["info"] as? [String: Any]
        let eventName = (
            object["hook_event_name"] as? String
                ?? object["hookEventName"] as? String
                ?? object["type"] as? String
                ?? ""
        ).lowercased()
        let sessionID = object["session_id"] as? String
            ?? object["conversation_id"] as? String
            ?? object["thread-id"] as? String
            ?? properties?["sessionID"] as? String
            ?? info?["id"] as? String
            ?? "\(provider.rawValue)-default"

        let phase: AgentPhase
        switch provider {
        case .claude:
            let notificationType = (object["notification_type"] as? String ?? "").lowercased()
            let attentionNotifications = [
                "permission_prompt",
                "idle_prompt",
                "elicitation_dialog",
                "agent_needs_input",
            ]
            if eventName == "permissionrequest"
                || (eventName == "notification" && attentionNotifications.contains(notificationType)) {
                phase = .waitingForInput
            } else if eventName == "stopfailure" {
                phase = .failed
            } else if eventName == "stop" {
                phase = .done
            } else if eventName == "sessionend" {
                phase = .idle
            } else if eventName == "notification" {
                phase = .idle
            } else {
                phase = .working
            }
        case .cursor:
            if eventName == "afteragentresponse" {
                phase = .waitingForInput
            } else if eventName == "stop" {
                phase = .done
            } else if eventName == "sessionend" {
                phase = .idle
            } else {
                phase = .working
            }
        case .codex:
            switch eventName {
            case "sessionstart", "sessionend": phase = .idle
            case "permissionrequest": phase = .waitingForInput
            case "stop", "agent-turn-complete": phase = .done
            case "subagentstop": phase = .working
            default: phase = .working
            }
        case .opencode:
            let status = properties?["status"]
            let statusType = (status as? [String: Any])?["type"] as? String
                ?? status as? String
                ?? ""
            switch eventName {
            case "permission.asked", "question.asked", "permissionasked", "questionasked":
                phase = .waitingForInput
            case "session.error", "sessionerror":
                phase = .failed
            case "session.idle", "sessionidle":
                phase = .done
            case "session.deleted", "sessiondeleted":
                phase = .idle
            case "session.status":
                phase = statusType.lowercased() == "idle" ? .done : .working
            case "sessionstatusidle":
                phase = .done
            default:
                phase = .working
            }
        case .gemini:
            let notificationType = (object["notification_type"] as? String ?? "").lowercased()
            switch eventName {
            case "sessionstart", "sessionend":
                phase = .idle
            case "notification" where notificationType == "toolpermission":
                phase = .waitingForInput
            case "afteragent":
                phase = .done
            default:
                phase = .working
            }
        case .pi:
            switch eventName {
            case "sessionstart", "sessionshutdown", "sessionend":
                phase = .idle
            case "agentfailed":
                phase = .failed
            case "agentsettled", "stop":
                phase = .done
            case "agentstart", "agentend", "turnstart", "turnend",
                 "toolexecutionstart", "toolexecutionend":
                phase = .working
            default:
                phase = .working
            }
        case .trae:
            let notificationType = (object["notification_type"] as? String ?? "").lowercased()
            switch eventName {
            case "sessionstart":
                phase = .idle
            case "notification" where notificationType == "idle_prompt":
                phase = .done
            case "notification" where ["permission_prompt", "document_review"].contains(notificationType):
                phase = .waitingForInput
            case "stop":
                phase = .done
            default:
                phase = .working
            }
        }
        return AgentEvent(provider: provider, sessionID: sessionID, phase: phase, timestamp: receivedAt, sourceEventName: eventName)
    }
}
