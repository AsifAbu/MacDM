import SafariServices
import Network
import os.log

/// Handles messages from the Safari Web Extension's background script.
///
/// This runs inside the SafariExtension app-extension process, which is a
/// separate module/sandbox from the main MacDM app, so it cannot see
/// DownloadManager directly. It forwards each message as JSON over the local
/// TCP socket (127.0.0.1:57642) to the app's NativeMessagingHost, waits for the
/// JSON reply, and hands that reply back to the extension's JavaScript.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let log = OSLog(subsystem: "com.macdm.SafariExtension", category: "handler")

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
            context.completeRequest(returningItems: nil)
            return
        }

        forwardToMacDM(message) { reply in
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    private func forwardToMacDM(_ message: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion(["ok": false, "error": "Invalid message"])
            return
        }

        let connection = NWConnection(host: "127.0.0.1", port: 57642, using: .tcp)
        var finished = false
        var received = Data()

        // All callbacks run on the main queue, so `finished` needs no locking.
        func finish(_ reply: [String: Any]) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(reply)
        }

        func receiveReply() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { chunk, _, isComplete, error in
                if let chunk, !chunk.isEmpty { received.append(chunk) }
                if isComplete || error != nil {
                    if let reply = (try? JSONSerialization.jsonObject(with: received)) as? [String: Any] {
                        finish(reply)
                    } else {
                        finish(["ok": false, "error": "MacDM did not respond. Is the app running?"])
                    }
                } else {
                    receiveReply()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        finish(["ok": false, "error": "Could not send to MacDM."])
                    } else {
                        receiveReply()
                    }
                })
            case .failed, .waiting:
                finish(["ok": false, "error": "MacDM is not running. Open the MacDM app and try again."])
            default:
                break
            }
        }
        connection.start(queue: .main)

        // yt-dlp can take a while on slow pages; give up eventually.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            finish(["ok": false, "error": "Timed out waiting for MacDM."])
        }
    }
}
