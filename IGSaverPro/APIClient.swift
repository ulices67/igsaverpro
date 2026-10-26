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

    static let defaultURL = "https://secondary-ranking-buffer-printers.trycloudflare.com"

    init() {
        let saved = UserDefaults.standard.string(forKey: "ig_server_url")
        // Si el valor guardado es un túnel trycloudflare antiguo que ya caducó, restablecer al activo
        if let saved = saved, saved.contains(".trycloudflare.com") && saved != APIClient.defaultURL {
            self.serverURL = APIClient.defaultURL
            UserDefaults.standard.set(APIClient.defaultURL, forKey: "ig_server_url")
        } else if let saved = saved, !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.serverURL = saved
        } else {
            self.serverURL = APIClient.defaultURL
        }
    }

    func resetToDefaultServer() {
        self.serverURL = APIClient.defaultURL
        UserDefaults.standard.set(APIClient.defaultURL, forKey: "ig_server_url")
        Task { await checkStatus() }
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
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SessionStatus.self, from: data)
            self.sessionStatus = decoded
        } catch {
            // Si falló por host no encontrado y no estábamos en defaultURL, auto-recuperar con defaultURL
            if serverURL != APIClient.defaultURL {
                self.serverURL = APIClient.defaultURL
                UserDefaults.standard.set(APIClient.defaultURL, forKey: "ig_server_url")
                if let fallbackURL = URL(string: "\(APIClient.defaultURL)/api/status"),
                   let (data2, _) = try? await URLSession.shared.data(from: fallbackURL),
                   let decoded2 = try? JSONDecoder().decode(SessionStatus.self, from: data2) {
                    self.sessionStatus = decoded2
                    return
                }
            }
            print("Status check error: \(error)")
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
        guard var comps = URLComponents(string: "\(serverURL)/api/search") else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
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
        guard var comps = URLComponents(string: "\(serverURL)/api/resolve") else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "url", value: input)]
        guard let url = comps.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let errObj = try? JSONDecoder().decode(LoginResponse.self, from: data)
            throw NSError(domain: "IGResolve", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: errObj?.detail ?? "No se pudo obtener el contenido"
            ])
        }
        return try JSONDecoder().decode(ResolveResponse.self, from: data)
    }

    func fetchHighlight(pk: String) async throws -> HighlightDetailResponse {
        guard let url = URL(string: "\(serverURL)/api/highlight/\(pk)") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
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
        let (data, _) = try await URLSession.shared.data(from: url)
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
