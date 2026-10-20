import Foundation

/// Builds URLSessionConfiguration honoring the user's proxy settings
/// (stored in UserDefaults/Keychain via the Settings > Proxy & Auth tab).
enum NetworkConfig {
    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0
        config.httpMaximumConnectionsPerHost = 16

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "proxyEnabled"),
              let host = defaults.string(forKey: "proxyHost"), !host.isEmpty,
              let portString = defaults.string(forKey: "proxyPort"), let port = Int(portString) else {
            return config
        }

        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port
        ]
        return config
    }

    /// Credentials used to answer NSURLAuthenticationChallenge for proxy
    /// auth and HTTP Basic/Digest-protected download links.
    static func credential(for challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest {
            let defaults = UserDefaults.standard
            let isProxyChallenge: Bool = challenge.protectionSpace.isProxy()
            let proxyEnabled: Bool = defaults.bool(forKey: "proxyEnabled")
            if isProxyChallenge && proxyEnabled {
                let username = defaults.string(forKey: "proxyUsername") ?? ""
                let password = CredentialStore.loadProxyPassword() ?? ""
                guard !username.isEmpty else { return (.performDefaultHandling, nil) }
                return (.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
            }
            let host = challenge.protectionSpace.host
            if let saved = SiteCredentialCache.shared.credential(for: host) {
                return (.useCredential, URLCredential(user: saved.username, password: saved.password, persistence: .forSession))
            }
        }
        return (.performDefaultHandling, nil)
    }
}

/// Holds site login credentials entered for the current session (and optionally
/// saved to Keychain) so retried segments don't re-prompt the user.
final class SiteCredentialCache {
    static let shared = SiteCredentialCache()
    private var cache: [String: (username: String, password: String)] = [:]

    func set(host: String, username: String, password: String, remember: Bool) {
        cache[host] = (username, password)
        if remember {
            CredentialStore.saveSiteCredential(host: host, username: username, password: password)
        }
    }

    func credential(for host: String) -> (username: String, password: String)? {
        cache[host]
    }
}
