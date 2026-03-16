import Foundation
import WebKit
import Security
import CommonCrypto

// Headless WKWebView token extractor for Microsoft Teams
// Uses OAuth2 implicit flow with redirect interception (inspired by fossteams/teams-token)
// PIV/smart card cert from macOS Keychain for TLS client auth
// Outputs JSON to stdout, logs to stderr
// Exit codes: 0 = success, 1 = error, 2 = needs Safari

let TEAMS_APP_ID = "5e3ce6c0-2b1f-4285-8d4b-75ee78787346"
let SKYPE_RESOURCE = "https://api.spaces.skype.com"
let GRAPH_RESOURCE = "https://graph.microsoft.com"
let REDIRECT_URI = "https://teams.microsoft.com/go"

class TokenExtractor: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let timeoutSeconds: Int
    private var started = Date()
    private var loginPageCount = 0
    private let loginPageThreshold = 30

    // Collected tokens
    private var teamsToken: String?
    private var skypeToken: String?
    private var graphToken: String?
    private var refreshToken: String?
    private var tenantId: String?
    private var loginHint: String?

    // PKCE for authorization code flow
    private var codeVerifier: String?

    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    init(timeout: Int, loginHint: String?, tenantId: String?) {
        self.timeoutSeconds = timeout
        self.loginHint = loginHint
        self.tenantId = tenantId
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.customUserAgent = Self.safariUA
    }

    func run() {
        started = Date()
        log("Starting OAuth flow...")
        authorizeTeams()

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) { [weak self] in
            self?.fail("Timeout after \(self?.timeoutSeconds ?? 0)s")
        }
    }

    // MARK: - OAuth flow

    private func authorizeTeams() {
        let tenant = tenantId ?? "common"
        let url = buildAuthorizeURL(responseType: "id_token", tenant: tenant)
        log("Requesting Teams id_token (tenant=\(tenant))...")
        webView.load(URLRequest(url: url))
    }

    private func authorizeSkype() {
        guard let tid = tenantId else {
            fail("No tenant ID for Skype authorization")
            return
        }
        let url = buildAuthorizeURL(responseType: "token", tenant: tid, resource: SKYPE_RESOURCE)
        log("Requesting Skype access_token...")
        webView.load(URLRequest(url: url))
    }

    private func authorizeGraph() {
        guard let tid = tenantId else {
            fail("No tenant ID for Graph authorization")
            return
        }
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(verifier)
        let baseURL = buildAuthorizeURL(responseType: "code", tenant: tid, resource: GRAPH_RESOURCE)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            fail("Failed to build Graph authorization URL")
            return
        }
        components.queryItems?.append(URLQueryItem(name: "code_challenge", value: challenge))
        components.queryItems?.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        guard let url = components.url else {
            fail("Failed to construct Graph authorization URL with PKCE")
            return
        }
        log("Requesting Graph authorization code...")
        webView.load(URLRequest(url: url))
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            fail("Failed to generate secure random bytes (status: \(status))")
            return ""
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(_ verifier: String) -> String {
        let data = verifier.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func buildAuthorizeURL(responseType: String, tenant: String, resource: String? = nil) -> URL {
        var components = URLComponents(string: "https://login.microsoftonline.com/\(tenant)/oauth2/authorize")!
        var items = [
            URLQueryItem(name: "response_type", value: responseType),
            URLQueryItem(name: "client_id", value: TEAMS_APP_ID),
            URLQueryItem(name: "redirect_uri", value: REDIRECT_URI),
            URLQueryItem(name: "state", value: UUID().uuidString),
            URLQueryItem(name: "nonce", value: UUID().uuidString),
        ]
        if let resource = resource {
            items.append(URLQueryItem(name: "resource", value: resource))
        }
        if let hint = loginHint {
            items.append(URLQueryItem(name: "login_hint", value: hint))
            if let domain = hint.split(separator: "@").last {
                items.append(URLQueryItem(name: "domain_hint", value: String(domain)))
            }
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let urlStr = url.absoluteString
        if urlStr.hasPrefix(REDIRECT_URI + "#") || urlStr.hasPrefix(REDIRECT_URI + "?") {
            decisionHandler(.cancel)
            handleRedirect(url: url)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            log("Client cert requested from \(challenge.protectionSpace.host)")
            if let credential = findPIVCredential() {
                completionHandler(.useCredential, credential)
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }

        if url.contains("login.microsoftonline.com") {
            loginPageCount += 1
            autoClickKMSI()
            if loginPageCount >= loginPageThreshold {
                needsSafari()
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        if code != 102 { // 102 = frame load interrupted (expected from cancel)
            log("Load error (\(code)): \(error.localizedDescription)")
        }
    }

    // MARK: - Redirect handling

    private func handleRedirect(url: URL) {
        let fragmentParams = parseFragment(url.fragment ?? "")
        let queryParams = parseFragment(url.query ?? "")

        if let error = fragmentParams["error"] ?? queryParams["error"] {
            let desc = (fragmentParams["error_description"] ?? queryParams["error_description"])?
                .removingPercentEncoding ?? "unknown"
            log("OAuth error: \(error) — \(desc)")
            if error == "interaction_required" { needsSafari() } else { fail("OAuth error: \(error)") }
            return
        }

        if let idToken = fragmentParams["id_token"] {
            handleTeamsToken(idToken)
        } else if let accessToken = fragmentParams["access_token"] {
            handleAccessToken(accessToken)
        } else if let code = queryParams["code"] {
            exchangeCodeForTokens(code)
        } else {
            log("Unrecognized redirect — no token, code, or error")
        }
    }

    private func handleTeamsToken(_ token: String) {
        teamsToken = token

        guard let payload = decodeJWT(token) else {
            fail("Failed to decode Teams JWT")
            return
        }

        tenantId = payload["tid"] as? String
        loginHint = loginHint ?? (payload["upn"] as? String)
        log("Got Teams token (tenant=\(tenantId ?? "?"), upn=\(loginHint ?? "?"))")
        authorizeSkype()
    }

    private func handleAccessToken(_ token: String) {
        guard let payload = decodeJWT(token) else { return }
        let audience = payload["aud"] as? String ?? "unknown"

        if audience == SKYPE_RESOURCE {
            log("Got Skype spaces token")
            skypeToken = token
            authorizeGraph()
        } else if audience == GRAPH_RESOURCE {
            log("Got Graph access token")
            graphToken = token
            emitResult()
        } else {
            log("Unexpected token audience: \(audience)")
        }
    }

    // MARK: - Authorization code exchange

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func exchangeCodeForTokens(_ code: String) {
        guard let tid = tenantId else { fail("No tenant ID for code exchange"); return }

        let tokenURL = URL(string: "https://login.microsoftonline.com/\(tid)/oauth2/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://teams.microsoft.com", forHTTPHeaderField: "Origin")

        var bodyParts = [
            "grant_type=authorization_code",
            "client_id=\(urlEncode(TEAMS_APP_ID))",
            "code=\(urlEncode(code))",
            "redirect_uri=\(urlEncode(REDIRECT_URI))",
            "resource=\(urlEncode(GRAPH_RESOURCE))"
        ]
        if let verifier = codeVerifier {
            bodyParts.append("code_verifier=\(urlEncode(verifier))")
        }
        let body = bodyParts.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        log("Exchanging authorization code for Graph tokens...")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.handleCodeExchangeResult(data, error) }
        }.resume()
    }

    private func handleCodeExchangeResult(_ data: Data?, _ error: Error?) {
        if let error = error { fail("Code exchange error: \(error.localizedDescription)"); return }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("Failed to parse code exchange response")
            return
        }

        if let err = json["error"] as? String {
            fail("Code exchange failed: \(err) — \(json["error_description"] as? String ?? "")")
            return
        }

        guard let accessToken = json["access_token"] as? String else {
            fail("No access_token in code exchange response")
            return
        }

        graphToken = accessToken
        refreshToken = json["refresh_token"] as? String
        log("Got Graph access token + refresh token")
        emitResult()
    }

    // MARK: - Auto-click "Stay signed in?"

    private func autoClickKMSI() {
        webView.evaluateJavaScript("""
            (function() {
                var btn = document.getElementById('idSIButton9');
                if (btn) { btn.click(); return 'clicked'; }
                return null;
            })()
        """) { result, _ in
            if let action = result as? String {
                self.log("KMSI: \(action)")
            }
        }
    }

    // MARK: - Result output

    private func emitResult() {
        var result: [String: String] = [
            "client_id": TEAMS_APP_ID,
        ]
        if let g = graphToken {
            result["auth_token"] = g
        } else if let t = teamsToken {
            log("Warning: Graph token unavailable, falling back to Teams id_token")
            result["auth_token"] = t
        }
        if let s = skypeToken { result["skype_spaces_token"] = s }
        if let tid = tenantId { result["tenant_id"] = tid }
        if let rt = refreshToken { result["refresh_token"] = rt }

        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else {
            fail("Failed to serialize result")
            return
        }

        log("Success!")
        print(json)
        exit(0)
    }

    // MARK: - JWT decoding

    private func decodeJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        // JWT uses base64url encoding — convert to standard base64
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Helpers

    private func parseFragment(_ fragment: String) -> [String: String] {
        fragment.split(separator: "&").reduce(into: [:]) { result, pair in
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                result[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
    }

    private func findPIVCredential() -> URLCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity],
              let identity = identities.first else { return nil }

        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }

    private func log(_ message: String) {
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        FileHandle.standardError.write("[\(elapsed)s] \(message)\n".data(using: .utf8)!)
    }

    private func needsSafari() {
        log("Stuck on login — Safari required")
        printJSON(["error": "needs_safari", "message": "No Entra ID session, Safari login required"])
        exit(2)
    }

    private func fail(_ message: String) {
        log("FAILED: \(message)")
        printJSON(["error": message])
        exit(1)
    }

    private func printJSON(_ dict: [String: String]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }
}

// MARK: - Main

var timeout = 90
var loginHint: String?
var tenantId: String?
var args = CommandLine.arguments.dropFirst()

while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--timeout":
        timeout = Int(args.first ?? "") ?? 90
        args = args.dropFirst()
    case "--login-hint":
        loginHint = String(args.first ?? "")
        args = args.dropFirst()
    case "--tenant-id":
        tenantId = String(args.first ?? "")
        args = args.dropFirst()
    default:
        break
    }
}

let extractor = TokenExtractor(timeout: timeout, loginHint: loginHint, tenantId: tenantId)
extractor.run()
RunLoop.main.run()
