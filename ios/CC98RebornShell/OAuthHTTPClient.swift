import Foundation

// Independent App authorization only. Never uses the forum WKWebsiteDataStore.
final class OAuthHTTPClient: NSObject, URLSessionTaskDelegate {
    func binding(code: String, verifier: String, userID: String) async throws -> OAuthBinding {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var exchange = URLRequest(url: OAuthProtocol.token)
            exchange.httpMethod = "POST"
            exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            exchange.setValue("application/json", forHTTPHeaderField: "Accept")
            exchange.httpBody = OAuthProtocol.tokenBody(code: code, verifier: verifier)
            let (tokenData, tokenResponse) = try await session.data(for: exchange)
            guard tokenResponse.url == OAuthProtocol.token, let tokenHTTP = tokenResponse as? HTTPURLResponse else { throw OAuthFailure.invalidToken }
            let token = try OAuthProtocol.accessToken(data: tokenData, status: tokenHTTP.statusCode)
            try Task.checkCancellation()
            var profile = URLRequest(url: OAuthProtocol.me)
            profile.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            profile.setValue("application/json", forHTTPHeaderField: "Accept")
            let (profileData, profileResponse) = try await session.data(for: profile)
            guard profileResponse.url == OAuthProtocol.me, let profileHTTP = profileResponse as? HTTPURLResponse else { throw OAuthFailure.invalidProfile }
            try Task.checkCancellation()
            return try OAuthProtocol.binding(data: profileData, status: profileHTTP.statusCode, expectedUserID: userID)
        } catch let error as OAuthFailure { throw error }
        catch is CancellationError { throw OAuthFailure.cancelled }
        catch { throw OAuthFailure.network }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // No redirected recipient may receive the code/verifier or bearer credential.
        completionHandler(nil)
    }
}
