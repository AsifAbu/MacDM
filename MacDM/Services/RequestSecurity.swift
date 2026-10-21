import Foundation

/// Who may talk to MacDM's local server, and what they may ask for.
///
/// The server only listens on this Mac (127.0.0.1), but any web page or program
/// on the Mac can still try to reach it, so every request is checked.
enum RequestSecurity {
    /// The Chrome extension ID. It is fixed by the public `key` in
    /// ChromeExtension/manifest.json, so it is the same on every machine.
    /// (A test checks that the two stay in sync.)
    /// If the extension is later published on the Chrome Web Store with a
    /// different ID, add that ID here.
    static let chromeExtensionIDs: Set<String> = ["iocffmeejelkamedgocfjaefbdlofhec"]

    /// True if `origin` is the MacDM Chrome extension or a Safari web extension.
    ///
    /// Safari gives each install a random ID that can't be known in advance, so any
    /// Safari web extension is accepted; installing one is an explicit user action.
    /// Ordinary web pages (https://…, http://…, null) are never accepted, and neither
    /// are other Chrome extensions.
    static func isAllowedOrigin(_ origin: String?, chromeExtensionIDs: Set<String> = RequestSecurity.chromeExtensionIDs) -> Bool {
        guard let origin else { return false }
        if origin.hasPrefix("chrome-extension://") {
            let id = origin.dropFirst("chrome-extension://".count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return chromeExtensionIDs.contains(id)
        }
        if origin.hasPrefix("safari-web-extension://") {
            let id = origin.dropFirst("safari-web-extension://".count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !id.isEmpty
        }
        return false
    }

    /// Accepts only real web addresses (http or https with a host). Rejects
    /// file://, javascript:, data: and anything else a request might try to use
    /// to read local files or run something unexpected.
    static func webURL(from string: String?) -> URL? {
        guard let string, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The request headers a browser extension may pass on so a download looks like the browser's own
    /// (the page it came from, its cookies, its identity). Anything else is dropped. Returns nil if
    /// nothing usable is left.
    static func safeHeaders(_ raw: Any?) -> [String: String]? {
        guard let dict = raw as? [String: Any] else { return nil }
        let canonicalNames = ["referer": "Referer", "cookie": "Cookie", "user-agent": "User-Agent",
                              "origin": "Origin", "accept-language": "Accept-Language"]
        var result: [String: String] = [:]
        for (name, value) in dict {
            guard let canonical = canonicalNames[name.lowercased()], let text = value as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.count <= (canonical == "Cookie" ? 8192 : 2048),
                  // No line breaks or control characters: they could smuggle in extra headers.
                  !trimmed.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" || $0.value == 127 }) else { continue }
            if canonical == "Referer" || canonical == "Origin", webURL(from: trimmed) == nil { continue }
            result[canonical] = trimmed
        }
        return result.isEmpty ? nil : result
    }

    /// Turns a file name suggested by a web page into a safe single file name.
    ///
    /// A page controls this text, so a name like "../../Library/LaunchAgents/x.plist"
    /// must never be able to place a file outside the download folder.
    static func safeFileName(_ name: String, fallback: String = "download") -> String {
        // Keep only the last path component, whichever slash style was used.
        var cleaned = name
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last.map(String.init) ?? ""
        // Remove characters that are invalid or hazardous in file names.
        cleaned = String(cleaned.unicodeScalars.filter { scalar in
            scalar.value >= 32 && scalar.value != 127 && scalar != ":"
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        // No hidden files and no "." or ".." names.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { return fallback }
        // Keep names within the file system's limit (255 bytes), preserving the extension.
        if cleaned.utf8.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let base = String((cleaned as NSString).deletingPathExtension.prefix(150))
            cleaned = ext.isEmpty ? base : base + "." + String(ext.prefix(20))
        }
        return cleaned
    }
}

/// One cookie the browser extension sends from the page the user is on, so a download can use the same sign-in.
struct BrowserCookie: Equatable {
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Int          // seconds since 1970; 0 for a session cookie
    var name: String
    var value: String
}

extension RequestSecurity {
    static let maxCookies = 400

    /// The cookies in a message, keeping only well-formed ones. A cookie is dropped when a field could break the
    /// cookie file's tab-separated lines (tabs, line breaks), when the domain is not a plain host name, or when
    /// it is oversized, so nothing in a message can add lines or fields of its own.
    static func safeCookies(_ raw: Any?) -> [BrowserCookie] {
        guard let list = raw as? [[String: Any]] else { return [] }
        func clean(_ value: Any?, limit: Int) -> String? {
            guard let text = value as? String, !text.isEmpty, text.count <= limit,
                  !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            return text
        }
        var result: [BrowserCookie] = []
        for item in list.prefix(maxCookies) {
            guard let domain = clean(item["domain"], limit: 253),
                  domain.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }),
                  let path = clean(item["path"], limit: 1024), path.hasPrefix("/"),
                  let name = clean(item["name"], limit: 256), !name.contains("="),
                  let value = clean(item["value"] ?? "", limit: 4096) ?? ((item["value"] as? String) == "" ? "" : nil)
            else { continue }
            let expires = (item["expires"] as? NSNumber)?.intValue ?? 0
            result.append(BrowserCookie(domain: domain, path: path, secure: item["secure"] as? Bool ?? false,
                                        httpOnly: item["httpOnly"] as? Bool ?? false, expires: max(0, expires),
                                        name: name, value: value))
        }
        return result
    }
}
