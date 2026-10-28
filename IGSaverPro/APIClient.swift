import Foundation
import UIKit
import Photos
import Security
import Combine

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

    init() {
        // Old saved tunnels must never override the production endpoint.
        UserDefaults.standard.removeObject(forKey: "ig_server_url")
        do {
            installationToken = try Self.loadInstallationToken()
        } catch {
            errorMessage = "No se pudo preparar la conexión segura. Desbloquea el iPhone y vuelve a abrir la app."
        }
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

    func checkStatus() async {
        guard let url = URL(string: "\(serverURL)/api/status") else { return }
        do {
            let (data, _) = try await requestData(for: URLRequest(url: url))
            sessionStatus = try JSONDecoder().decode(SessionStatus.self, from: data)
        } catch {
            isServiceAvailable = false
            errorMessage = error.localizedDescription
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
        await checkStatus()
        return decoded.message ?? "Sesión iniciada"
    }

    func logout() async {
        guard let url = URL(string: "\(serverURL)/api/logout") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            _ = try await requestData(for: req)
            await checkStatus()
        } catch {
            errorMessage = error.localizedDescription
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
        guard let url = URL(string: "\(serverURL)/api/highlight/\(pk)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
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

    /// Descarga una foto o video desde Instagram y lo guarda directamente en el carrete de FOTOS de iOS
    func saveMediaToPhotos(item: StoryItem) async {
        guard let url = proxyURL(for: item.url, filename: item.filename) else { return }
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                self.errorMessage = "Permiso denegado para guardar en Fotos. Actívalo en Ajustes."
                return
            }

            let (localTempURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                  contentType.hasPrefix("image/") || contentType.hasPrefix("video/") else {
                try? FileManager.default.removeItem(at: localTempURL)
                throw NSError(domain: "IGSaver", code: 502, userInfo: [NSLocalizedDescriptionKey:
                    "No se pudo descargar el archivo. Inténtalo de nuevo."])
            }
            let ext = item.media_type == "video" ? "mp4" : "jpg"
            let targetURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            defer { try? FileManager.default.removeItem(at: targetURL) }
            try FileManager.default.moveItem(at: localTempURL, to: targetURL)

            try await PHPhotoLibrary.shared().performChanges {
                if item.media_type == "video" {
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
