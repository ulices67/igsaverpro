import Foundation
import UIKit
import Photos
import Security
import Combine
import CryptoKit

@MainActor
class APIClient: ObservableObject {
    private let serverURL = APIClient.cloudWorkerURL
    private var installationToken: String?
    @Published private(set) var isServiceAvailable = false
    @Published var sessionStatus = SessionStatus(logged_in: false, user_id: nil, username: nil, session_file_exists: false)
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    static let cloudWorkerURL = "https://igsaver-cloud.societext.workers.dev"

    private static let sessionKeyService = "com.igsaverpro.auth"
    private static let sessionKeyAccount = "instagram_sessionid"
    private static let sessionStatusDefaultsKey = "ig_cached_session_status"

    init() {
        // Old saved tunnels must never override the production endpoint.
        UserDefaults.standard.removeObject(forKey: "ig_server_url")
        do {
            installationToken = try Self.loadInstallationToken()
        } catch {
            errorMessage = "No se pudo preparar la conexión segura. Desbloquea el iPhone y vuelve a abrir la app."
        }

        // Cargar inmediatamente la sesión guardada localmente para inicio instantáneo (0s espera)
        if let cached = Self.loadCachedSessionStatus(), cached.logged_in {
            self.sessionStatus = cached
            self.isServiceAvailable = true
        }
    }

    static func saveSessionId(_ sessionid: String) {
        let trimmed = sessionid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionKeyService,
            kSecAttrAccount as String: sessionKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadSavedSessionId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionKeyService,
            kSecAttrAccount as String: sessionKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let sid = String(data: data, encoding: .utf8) {
            let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func deleteSavedSessionId() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionKeyService,
            kSecAttrAccount as String: sessionKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveCachedSessionStatus(_ status: SessionStatus) {
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: sessionStatusDefaultsKey)
        }
    }

    static func loadCachedSessionStatus() -> SessionStatus? {
        guard let data = UserDefaults.standard.data(forKey: sessionStatusDefaultsKey),
              let status = try? JSONDecoder().decode(SessionStatus.self, from: data) else {
            return nil
        }
        return status
    }

    static func clearCachedSessionStatus() {
        UserDefaults.standard.removeObject(forKey: sessionStatusDefaultsKey)
    }

    private static func loadInstallationToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.igsaverpro.connection",
            kSecAttrAccount as String: "installation"
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(read as CFDictionary, &item)
        if result == errSecSuccess, let data = item as? Data,
           let token = String(data: data, encoding: .utf8) {
            return token
        }
        guard result == errSecItemNotFound else { throw URLError(.userAuthenticationRequired) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw URLError(.userAuthenticationRequired)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw URLError(.userAuthenticationRequired)
        }
        return token
    }

    private func requestData(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let token = installationToken else {
            throw NSError(domain: "IGSaver", code: 401, userInfo: [NSLocalizedDescriptionKey:
                "No se pudo acceder a la conexión segura. Vuelve a abrir la app."])
        }
        var authenticated = request
        authenticated.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        authenticated.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // A sleeping cloud container needs time to start.
        authenticated.timeoutInterval = 90
        do {
            let result = try await URLSession.shared.data(for: authenticated)
            guard let response = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if !(200..<300).contains(response.statusCode) {
                if response.statusCode >= 500 { isServiceAvailable = false }
                let detail = (try? JSONDecoder().decode(LoginResponse.self, from: result.0))?.detail
                let message = response.statusCode >= 500
                    ? "El servicio no está disponible temporalmente. Inténtalo de nuevo en unos momentos."
                    : (detail ?? "No se pudo completar la operación.")
                throw NSError(domain: "IGSaver", code: response.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            isServiceAvailable = true
            return result
        } catch let error as URLError {
            isServiceAvailable = false
            let message = error.code == .notConnectedToInternet
                ? "No hay conexión a internet. Revisa el Wi-Fi o tus datos móviles."
                : "No se pudo conectar con el servicio. Inténtalo de nuevo en unos momentos."
            throw NSError(domain: "IGSaver", code: error.errorCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func proxyURL(for rawURL: String, filename: String = "media.jpg") -> URL? {
        guard installationToken != nil,
              var comps = URLComponents(string: "\(serverURL)/api/proxy-file") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "file_url", value: rawURL),
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "access_token", value: installationToken)
        ]
        return comps.url
    }

    func checkStatus(silent: Bool = false) async {
        guard let url = URL(string: "\(serverURL)/api/status") else { return }
        do {
            let (data, _) = try await requestData(for: URLRequest(url: url))
            let status = try JSONDecoder().decode(SessionStatus.self, from: data)
            if status.logged_in {
                self.sessionStatus = status
                Self.saveCachedSessionStatus(status)
                self.isServiceAvailable = true
            } else if let savedSid = Self.loadSavedSessionId(), !savedSid.isEmpty {
                // El contenedor en la nube se reinició o despertó en frío.
                // Restauramos la sesión en segundo plano con la cookie guardada en el Keychain.
                do {
                    let restorePayload = LoginPayload(username: nil, password: nil, verification_code: nil, sessionid: savedSid)
                    _ = try await self.loginSilent(payload: restorePayload)
                } catch {
                    Self.deleteSavedSessionId()
                    Self.clearCachedSessionStatus()
                    self.sessionStatus = status
                }
            } else {
                self.sessionStatus = status
                Self.clearCachedSessionStatus()
            }
        } catch {
            if !silent {
                isServiceAvailable = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loginSilent(payload: LoginPayload) async throws {
        guard let url = URL(string: "\(serverURL)/api/login") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await requestData(for: req)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        let restored = SessionStatus(
            logged_in: true,
            user_id: nil,
            username: decoded.username ?? sessionStatus.username,
            session_file_exists: true
        )
        self.sessionStatus = restored
        Self.saveCachedSessionStatus(restored)
        self.isServiceAvailable = true
        if let sid = payload.sessionid ?? decoded.sessionid, !sid.isEmpty {
            Self.saveSessionId(sid)
        }
    }

    func login(payload: LoginPayload) async throws -> String {
        guard let url = URL(string: "\(serverURL)/api/login") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await requestData(for: req)
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
            throw NSError(domain: "IGLogin", code: httpResp.statusCode, userInfo: [
                NSLocalizedDescriptionKey: decoded.detail ?? "Error al iniciar sesión"
            ])
        }

        if let sid = payload.sessionid ?? decoded.sessionid, !sid.isEmpty {
            Self.saveSessionId(sid)
        }
        let updated = SessionStatus(
            logged_in: true,
            user_id: nil,
            username: decoded.username ?? sessionStatus.username,
            session_file_exists: true
        )
        self.sessionStatus = updated
        Self.saveCachedSessionStatus(updated)
        self.isServiceAvailable = true

        await checkStatus(silent: true)
        return decoded.message ?? "Sesión iniciada"
    }

    func logout() async {
        Self.deleteSavedSessionId()
        Self.clearCachedSessionStatus()
        sessionStatus = SessionStatus(logged_in: false, user_id: nil, username: nil, session_file_exists: false)
        guard let url = URL(string: "\(serverURL)/api/logout") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            _ = try await requestData(for: req)
        } catch {
            // Local state already erased
        }
    }

    func searchAccounts(query: String) async throws -> [SearchUser] {
        try await executeSearch(query: query)
    }

    private func executeSearch(query: String) async throws -> [SearchUser] {
        guard var comps = URLComponents(string: "\(serverURL)/api/search") else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, response) = try await requestData(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let errObj = try? JSONDecoder().decode(LoginResponse.self, from: data)
            throw NSError(domain: "IGSearch", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: errObj?.detail ?? "Error al buscar cuentas"
            ])
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.users
    }

    func resolve(input: String) async throws -> ResolveResponse {
        try await executeResolve(input: input)
    }

    private func executeResolve(input: String) async throws -> ResolveResponse {
        guard var comps = URLComponents(string: "\(serverURL)/api/resolve") else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "url", value: input)]
        guard let url = comps.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        let (data, response) = try await requestData(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let errObj = try? JSONDecoder().decode(LoginResponse.self, from: data)
            throw NSError(domain: "IGResolve", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: errObj?.detail ?? "No se pudo obtener el contenido"
            ])
        }
        return try JSONDecoder().decode(ResolveResponse.self, from: data)
    }

    func fetchHighlight(pk: String) async throws -> HighlightDetailResponse {
        try await executeFetchHighlight(pk: pk)
    }

    private func executeFetchHighlight(pk: String) async throws -> HighlightDetailResponse {
        let cleanPK = pk.filter(\.isNumber)
        guard !cleanPK.isEmpty,
              let url = URL(string: "\(serverURL)/api/highlight/\(cleanPK)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        let (data, _) = try await requestData(for: req)
        return try JSONDecoder().decode(HighlightDetailResponse.self, from: data)
    }

    func fetchMorePosts(userId: String, username: String, cursor: String) async throws -> MorePostsResponse {
        guard var comps = URLComponents(string: "\(serverURL)/api/user-posts/\(userId)") else {
            throw URLError(.badURL)
        }
        comps.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "cursor", value: cursor)
        ]
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, _) = try await requestData(for: req)
        return try JSONDecoder().decode(MorePostsResponse.self, from: data)
    }

    /// Descarga un recurso multimedia (foto o video de historia/destacada) a caché local con extensión real (.mp4/.jpg).
    /// Intenta primero descarga directa desde CDN de Instagram (sigue redirecciones 302 rápido) y usa el proxy de respaldo.
    func downloadMediaToCache(rawURL: String, filename: String = "media", expectVideo: Bool) async throws -> URL {
        let clean = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "None" else {
            throw URLError(.badURL)
        }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ig_story_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let hash = SHA256.hash(data: Data(clean.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = expectVideo ? "mp4" : "jpg"
        let cachedURL = cacheDir.appendingPathComponent("\(hash).\(ext)")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: cachedURL.path),
           let size = attrs[.size] as? Int, size > 512 {
            return cachedURL
        }

        if let directURL = URL(string: clean),
           let saved = await fetchAndStoreMedia(from: directURL, cachedURL: cachedURL, cacheDir: cacheDir, ext: ext, expectVideo: expectVideo, useAuth: false) {
            return saved
        }

        if let proxiedURL = proxyURL(for: clean, filename: filename),
           let saved = await fetchAndStoreMedia(from: proxiedURL, cachedURL: cachedURL, cacheDir: cacheDir, ext: ext, expectVideo: expectVideo, useAuth: true) {
            return saved
        }

        throw NSError(domain: "IGSaverMedia", code: 502, userInfo: [
            NSLocalizedDescriptionKey: "No se pudo cargar el archivo multimedia. Inténtalo de nuevo."
        ])
    }

    private func fetchAndStoreMedia(
        from remoteURL: URL,
        cachedURL: URL,
        cacheDir: URL,
        ext: String,
        expectVideo: Bool,
        useAuth: Bool
    ) async -> URL? {
        var req = URLRequest(url: remoteURL)
        req.timeoutInterval = 35
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        if useAuth, let token = installationToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let tempURL: URL
        let resp: URLResponse
        do {
            (tempURL, resp) = try await URLSession.shared.download(for: req)
        } catch {
            return nil
        }
        guard let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ct.hasPrefix("application/json") || ct.hasPrefix("text/") {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let size = attrs[.size] as? Int, size > 512 else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        let stagedURL = cacheDir.appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try FileManager.default.moveItem(at: tempURL, to: stagedURL)
            if !expectVideo && UIImage(contentsOfFile: stagedURL.path) == nil {
                try? FileManager.default.removeItem(at: stagedURL)
                return nil
            }
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                try? FileManager.default.removeItem(at: stagedURL)
                return cachedURL
            }
            try FileManager.default.moveItem(at: stagedURL, to: cachedURL)
            return cachedURL
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: stagedURL)
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                return cachedURL
            }
            return nil
        }
    }

    /// Descarga una foto o video desde Instagram y lo guarda directamente en el carrete de FOTOS de iOS
    func saveMediaToPhotos(item: StoryItem) async {
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                self.errorMessage = "Permiso denegado para guardar en Fotos. Actívalo en Ajustes."
                return
            }

            let isVideo = item.media_type == "video"
            let cachedFile = try await downloadMediaToCache(
                rawURL: item.url,
                filename: item.filename,
                expectVideo: isVideo
            )
            let ext = isVideo ? "mp4" : "jpg"
            let targetURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            defer { try? FileManager.default.removeItem(at: targetURL) }
            try FileManager.default.copyItem(at: cachedFile, to: targetURL)

            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: targetURL)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: targetURL)
                }
            }
            try? FileManager.default.removeItem(at: targetURL)
            self.toastMessage = "✅ Guardado en Fotos con éxito"
        } catch {
            if let networkError = error as? URLError {
                self.errorMessage = networkError.code == .notConnectedToInternet
                    ? "No hay conexión a internet. Revisa el Wi-Fi o tus datos móviles."
                    : "No se pudo descargar el archivo. Inténtalo de nuevo en unos momentos."
            } else {
                self.errorMessage = "Error al guardar en Fotos: \(error.localizedDescription)"
            }
        }
    }
}
