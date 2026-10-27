import Foundation
import UIKit
import Photos

@MainActor
class APIClient: ObservableObject {
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "ig_server_url")
        }
    }
    @Published var sessionStatus = SessionStatus(logged_in: false, user_id: nil, username: nil, session_file_exists: false)
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    @Published var isCloudSyncing = false

    // Enlace permanente 24/7 en la red global de Cloudflare Workers (nunca cambia ni se apaga)
    static let cloudWorkerURL = "https://igsaver-cloud.societext.workers.dev"
    static let defaultURL = "https://igsaver-cloud.societext.workers.dev"

    init() {
        let saved = UserDefaults.standard.string(forKey: "ig_server_url")
        // Migración automática: si tenía un túnel efímero antiguo, conectar al Cloudflare Worker permanente
        if saved == nil || saved?.contains(".trycloudflare.com") == true {
            self.serverURL = APIClient.cloudWorkerURL
            UserDefaults.standard.set(APIClient.cloudWorkerURL, forKey: "ig_server_url")
        } else if let saved = saved, !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.serverURL = saved
        } else {
            self.serverURL = APIClient.cloudWorkerURL
        }

        // Sincronización automática con la nube al arrancar
        Task {
            await syncWithCloudRegistry()
            await checkStatus()
        }
    }

    /// Consulta el registro permanente en GitHub para obtener siempre el servidor activo
    @discardableResult
    func syncWithCloudRegistry() async -> Bool {
        guard let url = URL(string: APIClient.cloudRegistryURL) else { return false }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 7

        isCloudSyncing = true
        defer { isCloudSyncing = false }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let remoteURL = json["server_url"] as? String {
                let cleanURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanURL.isEmpty && cleanURL != self.serverURL {
                    print("[CloudSync] Nuevo servidor detectado desde la nube: \(cleanURL)")
                    self.serverURL = cleanURL
                    UserDefaults.standard.set(cleanURL, forKey: "ig_server_url")
                    return true
                }
            }
        } catch {
            print("[CloudSync] Aviso: no se pudo consultar el registro en la nube (\(error.localizedDescription))")
        }
        return false
    }

    func resetToDefaultServer() {
        self.serverURL = APIClient.defaultURL
        UserDefaults.standard.set(APIClient.defaultURL, forKey: "ig_server_url")
        Task {
            await syncWithCloudRegistry()
            await checkStatus()
        }
    }

    func proxyURL(for rawURL: String, filename: String = "media.jpg") -> URL? {
        guard var comps = URLComponents(string: "\(serverURL)/api/proxy-file") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "file_url", value: rawURL),
            URLQueryItem(name: "filename", value: filename)
        ]
        return comps.url
    }

    func checkStatus() async {
        guard let url = URL(string: "\(serverURL)/api/status") else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(SessionStatus.self, from: data)
            self.sessionStatus = decoded
        } catch {
            print("[CheckStatus] Falló conexión con \(serverURL). Intentando auto-recuperar desde la nube...")
            let updated = await syncWithCloudRegistry()
            if updated, let retryURL = URL(string: "\(serverURL)/api/status") {
                if let (data2, _) = try? await URLSession.shared.data(from: retryURL),
                   let decoded2 = try? JSONDecoder().decode(SessionStatus.self, from: data2) {
                    self.sessionStatus = decoded2
                }
            }
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

        let (data, response) = try await URLSession.shared.data(for: req)
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
        _ = try? await URLSession.shared.data(for: req)
        await checkStatus()
    }

    func searchAccounts(query: String) async throws -> [SearchUser] {
        do {
            return try await executeSearch(query: query)
        } catch {
            if await syncWithCloudRegistry() {
                return try await executeSearch(query: query)
            }
            throw error
        }
    }

    private func executeSearch(query: String) async throws -> [SearchUser] {
        guard var comps = URLComponents(string: "\(serverURL)/api/search") else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
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
        do {
            return try await executeResolve(input: input)
        } catch {
            if await syncWithCloudRegistry() {
                return try await executeResolve(input: input)
            }
            throw error
        }
    }

    private func executeResolve(input: String) async throws -> ResolveResponse {
        guard var comps = URLComponents(string: "\(serverURL)/api/resolve") else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "url", value: input)]
        guard let url = comps.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let errObj = try? JSONDecoder().decode(LoginResponse.self, from: data)
            throw NSError(domain: "IGResolve", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: errObj?.detail ?? "No se pudo obtener el contenido"
            ])
        }
        return try JSONDecoder().decode(ResolveResponse.self, from: data)
    }

    func fetchHighlight(pk: String) async throws -> HighlightDetailResponse {
        do {
            return try await executeFetchHighlight(pk: pk)
        } catch {
            if await syncWithCloudRegistry() {
                return try await executeFetchHighlight(pk: pk)
            }
            throw error
        }
    }

    private func executeFetchHighlight(pk: String) async throws -> HighlightDetailResponse {
        guard let url = URL(string: "\(serverURL)/api/highlight/\(pk)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
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
        let (data, _) = try await URLSession.shared.data(for: req)
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

            let (localTempURL, _) = try await URLSession.shared.download(from: url)
            let ext = item.media_type == "video" ? "mp4" : "jpg"
            let targetURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            try? FileManager.default.removeItem(at: targetURL)
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
            self.errorMessage = "Error al guardar en Fotos: \(error.localizedDescription)"
        }
    }
}
