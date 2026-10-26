import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var api = APIClient()
    @State private var searchText = ""
    @State private var searchResults: [SearchUser] = []
    @State private var isSearching = false

    @State private var resolvedProfile: ResolveResponse?
    @State private var profilePosts: [PostItem] = []
    @State private var nextCursor: String = ""
    @State private var directItems: [StoryItem] = []

    // Modal de Destacadas (Fila / Cuadrícula / Selección Múltiple)
    @State private var showingHighlightSheet = false
    @State private var currentHighlightDetail: HighlightDetailResponse?

    // Visor Anónimo de Historias del perfil
    @State private var showingStoryViewer = false
    @State private var storyQueue: [StoryItem] = []
    @State private var storyIndex = 0
    @State private var storyHeaderTitle = ""

    // Hoja de Login y Detalle de Publicación
    @State private var showingLoginSheet = false
    @State private var selectedPost: PostItem?

    // Persistencia de Favoritos y Búsquedas Recientes
    @AppStorage("ig_fav_accounts") private var favAccountsJSON: String = "[]"
    @AppStorage("ig_recent_searches") private var recentSearchesJSON: String = "[]"

    private var favoriteAccounts: [SavedAccount] {
        guard let data = favAccountsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return [] }
        return list
    }

    private func saveFavorites(_ list: [SavedAccount]) {
        if let data = try? JSONEncoder().encode(list),
           let str = String(data: data, encoding: .utf8) {
            favAccountsJSON = str
        }
    }

    private var recentSearches: [SavedAccount] {
        guard let data = recentSearchesJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return [] }
        return list
    }

    private func saveRecentSearches(_ list: [SavedAccount]) {
        if let data = try? JSONEncoder().encode(list),
           let str = String(data: data, encoding: .utf8) {
            recentSearchesJSON = str
        }
    }

    private func isFavorite(username: String) -> Bool {
        favoriteAccounts.contains(where: { $0.username.lowercased() == username.lowercased() })
    }

    private func toggleFavorite(account: SavedAccount) {
        var list = favoriteAccounts
        if let idx = list.firstIndex(where: { $0.username.lowercased() == account.username.lowercased() }) {
            list.remove(at: idx)
        } else {
            list.insert(account, at: 0)
            if list.count > 25 { list.removeLast() }
        }
        saveFavorites(list)
    }

    private func addRecentSearch(account: SavedAccount) {
        var list = recentSearches
        list.removeAll(where: { $0.username.lowercased() == account.username.lowercased() })
        list.insert(account, at: 0)
        if list.count > 15 { list.removeLast() }
        saveRecentSearches(list)
    }

    private func clearRecentSearches() {
        saveRecentSearches([])
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        headerBar
                        searchAndInputCard

                        // Sección de Favoritos
                        if !favoriteAccounts.isEmpty {
                            favoritesTrayView
                        }

                        // Sección de Búsquedas Recientes
                        if !recentSearches.isEmpty {
                            recentSearchesTrayView
                        }

                        if !searchResults.isEmpty {
                            searchResultsList
                        }
                        if let prof = resolvedProfile, let user = prof.user {
                            profileExplorerSection(user: user, prof: prof)
                        }
                        if !directItems.isEmpty {
                            directMediaListSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 30)
                }
            }
            .preferredColorScheme(.dark)
            .task {
                await api.checkStatus()
            }
            .sheet(isPresented: $showingLoginSheet) {
                LoginSheetView(api: api)
            }
            .sheet(item: $selectedPost) { post in
                PostDetailSheetView(post: post, username: resolvedProfile?.user?.username ?? "user", api: api)
            }
            .sheet(isPresented: $showingHighlightSheet) {
                if let hl = currentHighlightDetail {
                    HighlightExplorerSheetView(
                        highlight: hl,
                        api: api
                    )
                }
            }
            .fullScreenCover(isPresented: $showingStoryViewer) {
                AnonymousStoryPlayerView(
                    items: storyQueue,
                    currentIndex: $storyIndex,
                    title: storyHeaderTitle,
                    api: api,
                    onClose: { showingStoryViewer = false }
                )
            }
            .alert("Aviso", isPresented: Binding(
                get: { api.errorMessage != nil || api.toastMessage != nil },
                set: { if !$0 { api.errorMessage = nil; api.toastMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(api.toastMessage ?? api.errorMessage ?? "")
            }
        }
    }

    // MARK: - Header
    private var headerBar: some View {
        HStack {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: [.orange, .pink, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 42, height: 42)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("IG Saver Pro")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                    Text("Buscador · Destacadas · Historias Anónimas")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }
            Spacer()
            Button {
                showingLoginSheet = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(api.sessionStatus.logged_in ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(api.sessionStatus.logged_in ? "@\(api.sessionStatus.username ?? "Conectado")" : "Iniciar Sesión")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
        }
    }

    // MARK: - Search & Input Card
    private var searchAndInputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🕵️‍♂️ Modo 100% Anónimo — No apareces en vistos")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.14))
                .clipShape(Capsule())

            HStack {
                TextField("Busca nombre, @usuario o pega link...", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .foregroundColor(.white)
                    .onSubmit {
                        Task { await handleResolve() }
                    }
                Button("Pegar") {
                    if let str = UIPasteboard.general.string {
                        searchText = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await handleResolve() }
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.pink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.pink.opacity(0.18))
                .cornerRadius(8)
            }
            .padding(13)
            .background(Color.black.opacity(0.5))
            .cornerRadius(14)

            HStack(spacing: 10) {
                Button {
                    Task { await runAccountSearch() }
                } label: {
                    HStack {
                        if isSearching { ProgressView().tint(.white) }
                        Text("🔍 Buscar Cuentas")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.1))
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }

                Button {
                    Task { await handleResolve() }
                } label: {
                    HStack {
                        if api.isLoading { ProgressView().tint(.white) }
                        Text("Abrir / Descargar")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(LinearGradient(
                        colors: [.orange, .pink, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.1, green: 0.1, blue: 0.14))
        .cornerRadius(20)
    }

    // MARK: - Bandeja de Favoritos
    private var favoritesTrayView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 12))
                Text("CUENTAS FAVORITAS (\(favoriteAccounts.count))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.yellow)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(favoriteAccounts) { fav in
                        Button {
                            searchText = "@\(fav.username)"
                            searchResults = []
                            Task { await handleResolve() }
                        } label: {
                            VStack(spacing: 4) {
                                AsyncImage(url: api.proxyURL(for: fav.profile_pic, filename: "\(fav.username)_fav.jpg")) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.yellow.opacity(0.2)
                                }
                                .frame(width: 54, height: 54)
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.yellow, lineWidth: 2)
                                )

                                Text("@\(fav.username)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 66)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(red: 0.1, green: 0.1, blue: 0.14))
        .cornerRadius(16)
    }

    // MARK: - Bandeja de Búsquedas Recientes
    private var recentSearchesTrayView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.gray)
                    .font(.system(size: 12))
                Text("BÚSQUEDAS RECIENTES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.gray)
                Spacer()
                Button("Borrar") {
                    clearRecentSearches()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.pink)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recentSearches) { item in
                        Button {
                            searchText = "@\(item.username)"
                            searchResults = []
                            Task { await handleResolve() }
                        } label: {
                            HStack(spacing: 7) {
                                AsyncImage(url: api.proxyURL(for: item.profile_pic, filename: "\(item.username)_rec.jpg")) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.gray.opacity(0.2)
                                }
                                .frame(width: 26, height: 26)
                                .clipShape(Circle())

                                Text("@\(item.username)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(18)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
        .cornerRadius(16)
    }

    // MARK: - Search Results
    private var searchResultsList: some View {
        VStack(spacing: 0) {
            ForEach(searchResults) { u in
                Button {
                    searchText = "@\(u.username)"
                    searchResults = []
                    Task { await handleResolve() }
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: api.proxyURL(for: u.profile_pic_url, filename: "\(u.username).jpg")) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .overlay(
                            Circle().stroke(
                                u.has_stories ? Color.pink : Color.clear,
                                lineWidth: 2
                            )
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("@\(u.username)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                if u.is_verified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.blue)
                                        .font(.system(size: 12))
                                }
                                if u.is_private {
                                    Image(systemName: "lock.fill")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 11))
                                }
                            }
                            Text(u.full_name)
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("Ver Perfil →")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.pink)
                    }
                    .padding(12)
                }
                Divider().background(Color.white.opacity(0.08))
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
        .cornerRadius(16)
    }

    // MARK: - Profile Section
    private func profileExplorerSection(user: ProfileUser, prof: ResolveResponse) -> some View {
        let stories = prof.stories ?? []
        let highlights = prof.highlights ?? []
        let hasStories = !stories.isEmpty
        let currentAccount = SavedAccount(
            username: user.username,
            full_name: user.full_name,
            profile_pic: user.profile_pic_hd
        )
        let isFav = isFavorite(username: user.username)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                AsyncImage(url: api.proxyURL(for: user.profile_pic_hd, filename: "\(user.username)_hd.jpg")) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 78, height: 78)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        hasStories
                            ? LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [.gray.opacity(0.4)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 3
                    )
                )
                .onTapGesture {
                    if hasStories {
                        storyQueue = stories
                        storyIndex = 0
                        storyHeaderTitle = "@\(user.username) · Historias"
                        showingStoryViewer = true
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("@\(user.username)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                        if user.is_verified {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.blue)
                        }
                        if user.is_private {
                            Image(systemName: "lock.fill").foregroundColor(.orange)
                        }
                    }
                    Text(user.full_name)
                        .font(.system(size: 13))
                        .foregroundColor(.gray)

                    HStack(spacing: 14) {
                        Text("**\(user.media_count)** posts").font(.system(size: 12))
                        Text("**\(user.follower_count)** seg.").font(.system(size: 12))
                        Text("**\(user.following_count)** sig.").font(.system(size: 12))
                    }
                    .foregroundColor(.white.opacity(0.85))
                }
            }

            if !user.biography.isEmpty {
                Text(user.biography)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
            }

            // Botón Favorito
            Button {
                toggleFavorite(account: currentAccount)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .foregroundColor(isFav ? .yellow : .white)
                    Text(isFav ? "En Favoritos" : "⭐ Añadir a Favoritos")
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isFav ? Color.yellow.opacity(0.18) : Color.white.opacity(0.08))
                .foregroundColor(isFav ? .yellow : .white)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFav ? Color.yellow.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1)
                )
            }

            HStack(spacing: 10) {
                Button {
                    if hasStories {
                        storyQueue = stories
                        storyIndex = 0
                        storyHeaderTitle = "@\(user.username) · Historias"
                        showingStoryViewer = true
                    } else {
                        api.toastMessage = "Este usuario no tiene historias activas hoy."
                    }
                } label: {
                    Text(hasStories ? "🕵️‍♂️ Ver Historias (\(stories.count))" : "Sin Historias Hoy")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(hasStories ? Color.pink.opacity(0.22) : Color.white.opacity(0.08))
                        .foregroundColor(hasStories ? .pink : .gray)
                        .cornerRadius(12)
                }

                Button {
                    let picItem = StoryItem(
                        pk: user.pk,
                        media_type: "photo",
                        url: user.profile_pic_hd,
                        thumbnail: user.profile_pic_hd,
                        taken_at: nil,
                        filename: "\(user.username)_profile_hd.jpg"
                    )
                    Task { await api.saveMediaToPhotos(item: picItem) }
                } label: {
                    Text("🖼️ Guardar Foto HD")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.1))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }

            // Bandeja de Destacadas
            if !highlights.isEmpty {
                Text("✨ HISTORIAS DESTACADAS (\(highlights.count))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.gray)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(highlights) { hl in
                            Button {
                                Task { await openHighlightExplorer(hl) }
                            } label: {
                                VStack(spacing: 5) {
                                    AsyncImage(url: api.proxyURL(for: hl.cover_url, filename: "hl_\(hl.pk).jpg")) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.gray.opacity(0.3)
                                    }
                                    .frame(width: 60, height: 60)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 2))

                                    Text(hl.title)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white)
                                        .frame(width: 64)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }

            // Grid de Publicaciones
            if !profilePosts.isEmpty {
                Text("PUBLICACIONES (\(profilePosts.count))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.gray)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(profilePosts) { p in
                        Button {
                            selectedPost = p
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                AsyncImage(url: api.proxyURL(for: p.thumbnail, filename: "\(p.code).jpg")) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.gray.opacity(0.2)
                                }
                                .frame(height: 115)
                                .clipped()

                                if p.items.count > 1 {
                                    Image(systemName: "square.fill.on.square.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white)
                                        .padding(5)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(Circle())
                                        .padding(4)
                                } else if p.media_type == "video" {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white)
                                        .padding(5)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(Circle())
                                        .padding(4)
                                }
                            }
                        }
                    }
                }

                if !nextCursor.isEmpty {
                    Button {
                        Task { await loadMorePosts(user: user) }
                    } label: {
                        Text("➕ Cargar más publicaciones")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.1, green: 0.1, blue: 0.14))
        .cornerRadius(20)
    }

    // MARK: - Direct Media Section
    private var directMediaListSection: some View {
        VStack(spacing: 14) {
            ForEach(directItems) { item in
                VStack(spacing: 10) {
                    AsyncImage(url: api.proxyURL(for: item.thumbnail ?? item.url, filename: item.filename)) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().frame(height: 200)
                    }
                    .frame(maxHeight: 360)
                    .cornerRadius(12)

                    Button {
                        Task { await api.saveMediaToPhotos(item: item) }
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("Guardar en Fotos")
                        }
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.pink)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
                .padding(14)
                .background(Color(red: 0.1, green: 0.1, blue: 0.14))
                .cornerRadius(18)
            }
        }
    }

    // MARK: - Actions
    private func runAccountSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await api.searchAccounts(query: q)
        } catch {
            api.errorMessage = error.localizedDescription
        }
    }

    private func handleResolve() async {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchResults = []
        api.isLoading = true
        defer { api.isLoading = false }

        do {
            let res = try await api.resolve(input: q)
            if res.type == "profile" {
                resolvedProfile = res
                profilePosts = res.posts ?? []
                nextCursor = res.next_cursor ?? ""
                directItems = []

                if let u = res.user {
                    addRecentSearch(account: SavedAccount(
                        username: u.username,
                        full_name: u.full_name,
                        profile_pic: u.profile_pic_hd
                    ))
                }
            } else {
                resolvedProfile = nil
                directItems = res.items ?? []
            }
        } catch {
            api.errorMessage = error.localizedDescription
        }
    }

    private func openHighlightExplorer(_ hl: HighlightTrayItem) async {
        api.isLoading = true
        defer { api.isLoading = false }
        do {
            let detail = try await api.fetchHighlight(pk: hl.pk)
            if detail.items.isEmpty {
                api.toastMessage = "Esta destacada no tiene historias activas."
                return
            }
            currentHighlightDetail = detail
            showingHighlightSheet = true
        } catch {
            api.errorMessage = error.localizedDescription
        }
    }

    private func loadMorePosts(user: ProfileUser) async {
        guard !nextCursor.isEmpty else { return }
        do {
            let more = try await api.fetchMorePosts(userId: user.pk, username: user.username, cursor: nextCursor)
            profilePosts.append(contentsOf: more.posts)
            nextCursor = more.next_cursor
        } catch {
            api.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Explorador de Destacadas (Ver en Fila / Modo Historias / Selección Múltiple)
struct HighlightExplorerSheetView: View {
    let highlight: HighlightDetailResponse
    @ObservedObject var api: APIClient
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIndices: Set<Int> = []
    @State private var isDownloadingBatch = false
    @State private var showingInnerViewer = false
    @State private var innerViewerIndex = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        innerViewerIndex = 0
                        showingInnerViewer = true
                    } label: {
                        HStack {
                            Image(systemName: "play.circle.fill")
                            Text("Ver una por una")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.pink.opacity(0.2))
                        .foregroundColor(.pink)
                        .cornerRadius(10)
                    }

                    Button {
                        if selectedIndices.count == highlight.items.count {
                            selectedIndices.removeAll()
                        } else {
                            selectedIndices = Set(highlight.items.indices)
                        }
                    } label: {
                        Text(selectedIndices.count == highlight.items.count ? "Deseleccionar" : "Seleccionar todas")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                HStack {
                    Text("\(selectedIndices.count) de \(highlight.items.count) seleccionadas")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        Task { await downloadSelectedItems() }
                    } label: {
                        HStack {
                            if isDownloadingBatch { ProgressView().tint(.white) }
                            Text(selectedIndices.isEmpty ? "Guardar selección" : "⬇️ Guardar (\(selectedIndices.count))")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selectedIndices.isEmpty ? Color.gray.opacity(0.3) : Color.pink)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(selectedIndices.isEmpty || isDownloadingBatch)
                }
                .padding(.horizontal, 16)

                // Cuadrícula 2 columnas de historias
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(highlight.items.indices, id: \.self) { idx in
                            let item = highlight.items[idx]
                            let isSelected = selectedIndices.contains(idx)

                            VStack(spacing: 0) {
                                ZStack(alignment: .topTrailing) {
                                    AsyncImage(url: api.proxyURL(for: item.thumbnail ?? item.url, filename: item.filename)) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.gray.opacity(0.2)
                                    }
                                    .frame(height: 190)
                                    .clipped()
                                    .onTapGesture {
                                        innerViewerIndex = idx
                                        showingInnerViewer = true
                                    }

                                    // Casilla de verificación
                                    Button {
                                        if isSelected {
                                            selectedIndices.remove(idx)
                                        } else {
                                            selectedIndices.insert(idx)
                                        }
                                    } label: {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(isSelected ? Color.pink : Color.black.opacity(0.6))
                                                .frame(width: 26, height: 26)
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 14, weight: .bold))
                                                    .foregroundColor(.white)
                                            }
                                        }
                                        .padding(8)
                                    }
                                }

                                HStack {
                                    Text(item.media_type == "video" ? "▶ Video" : "📷 Foto")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.gray)
                                    Spacer()
                                    Button {
                                        Task { await api.saveMediaToPhotos(item: item) }
                                    } label: {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.pink)
                                    }
                                }
                                .padding(8)
                                .background(Color(red: 0.1, green: 0.1, blue: 0.14))
                            }
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isSelected ? Color.pink : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.08))
            .navigationTitle("✨ \(highlight.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showingInnerViewer) {
                AnonymousStoryPlayerView(
                    items: highlight.items,
                    currentIndex: $innerViewerIndex,
                    title: "✨ \(highlight.title)",
                    api: api,
                    onClose: { showingInnerViewer = false }
                )
            }
        }
    }

    private func downloadSelectedItems() async {
        isDownloadingBatch = true
        defer { isDownloadingBatch = false }
        for idx in selectedIndices {
            let item = highlight.items[idx]
            await api.saveMediaToPhotos(item: item)
        }
        api.toastMessage = "✅ Se guardaron \(selectedIndices.count) historia(s) en Fotos."
    }
}

// MARK: - Reproductor de Video Robusto sin Pantalla Negra
struct StoryVideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?
    @State private var isMuted = true
    @State private var isBuffering = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let p = player {
                VideoPlayer(player: p)
                    .onAppear {
                        p.play()
                    }
                    .onDisappear {
                        p.pause()
                    }
            }

            if isBuffering {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            }

            Button {
                isMuted.toggle()
                player?.isMuted = isMuted
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Circle())
            }
            .padding(16)
        }
        .onAppear {
            let p = AVPlayer(url: videoURL)
            p.isMuted = isMuted
            p.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: p.currentItem,
                queue: .main
            ) { _ in
                p.seek(to: .zero)
                p.play()
            }
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                isBuffering = false
            }
            p.play()
            self.player = p
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Visor Anónimo de Historias (Una por una a pantalla completa)
struct AnonymousStoryPlayerView: View {
    let items: [StoryItem]
    @Binding var currentIndex: Int
    let title: String
    @ObservedObject var api: APIClient
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if items.indices.contains(currentIndex) {
                let current = items[currentIndex]
                VStack(spacing: 12) {
                    // Barras de progreso
                    HStack(spacing: 4) {
                        ForEach(items.indices, id: \.self) { idx in
                            Rectangle()
                                .fill(idx <= currentIndex ? Color.pink : Color.white.opacity(0.25))
                                .frame(height: 3)
                                .cornerRadius(2)
                        }
                    }
                    .padding(.horizontal, 12)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(title) (\(currentIndex + 1)/\(items.count))")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            Text("🕵️‍♂️ Viendo en Modo 100% Anónimo \(current.taken_at ?? "")")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                        }
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 16)

                    Spacer()

                    // Contenido Multimedia sin pantalla negra
                    ZStack {
                        if current.media_type == "video", let vURL = api.proxyURL(for: current.url, filename: current.filename) {
                            StoryVideoPlayerView(videoURL: vURL)
                                .id(current.id)
                        } else {
                            AsyncImage(url: api.proxyURL(for: current.url, filename: current.filename)) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView().tint(.white)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                case .failure:
                                    AsyncImage(url: URL(string: current.url)) { directImg in
                                        directImg.resizable().scaledToFit()
                                    } placeholder: {
                                        Image(systemName: "photo")
                                            .font(.system(size: 40))
                                            .foregroundColor(.gray)
                                    }
                                @unknown default:
                                    EmptyView()
                                }
                            }
                            .id(current.id)
                        }

                        HStack(spacing: 0) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if currentIndex > 0 { currentIndex -= 1 }
                                }
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if currentIndex < items.count - 1 {
                                        currentIndex += 1
                                    } else {
                                        onClose()
                                    }
                                }
                        }
                    }

                    Spacer()

                    Button {
                        Task { await api.saveMediaToPhotos(item: current) }
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("Guardar en Fotos")
                        }
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(14)
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }
}

// MARK: - Hoja Detalle de Publicación (Con Selección Múltiple)
struct PostDetailSheetView: View {
    let post: PostItem
    let username: String
    @ObservedObject var api: APIClient
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIndices: Set<Int> = []
    @State private var isDownloading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        if selectedIndices.count == post.items.count {
                            selectedIndices.removeAll()
                        } else {
                            selectedIndices = Set(post.items.indices)
                        }
                    } label: {
                        Text(selectedIndices.count == post.items.count ? "Deseleccionar" : "Seleccionar todas")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.pink)
                    }

                    Spacer()

                    Button {
                        Task { await downloadSelected() }
                    } label: {
                        HStack {
                            if isDownloading { ProgressView().tint(.white) }
                            Text(selectedIndices.isEmpty ? "Guardar selección" : "⬇️ Guardar (\(selectedIndices.count))")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selectedIndices.isEmpty ? Color.gray.opacity(0.3) : Color.pink)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(selectedIndices.isEmpty || isDownloading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(post.items.indices, id: \.self) { idx in
                            let item = post.items[idx]
                            let isSelected = selectedIndices.contains(idx)

                            VStack(spacing: 10) {
                                HStack {
                                    Text("Elemento #\(idx + 1) (\(item.media_type.uppercased()))")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Button {
                                        if isSelected { selectedIndices.remove(idx) }
                                        else { selectedIndices.insert(idx) }
                                    } label: {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(isSelected ? Color.pink : Color.white.opacity(0.1))
                                                .frame(width: 24, height: 24)
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundColor(.white)
                                            }
                                        }
                                    }
                                }

                                AsyncImage(url: api.proxyURL(for: item.thumbnail ?? item.url, filename: item.filename)) { img in
                                    img.resizable().scaledToFit()
                                } placeholder: {
                                    ProgressView().frame(height: 220)
                                }
                                .cornerRadius(12)

                                Button {
                                    Task { await api.saveMediaToPhotos(item: item) }
                                } label: {
                                    HStack {
                                        Image(systemName: "square.and.arrow.down.fill")
                                        Text("Guardar este archivo en Fotos")
                                    }
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.1))
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(isSelected ? Color.pink : Color.clear, lineWidth: 2)
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.08))
            .navigationTitle("@\(username) · \(post.items.count) archivo(s)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .onAppear {
                selectedIndices = Set(post.items.indices)
            }
        }
    }

    private func downloadSelected() async {
        isDownloading = true
        defer { isDownloading = false }
        for idx in selectedIndices {
            let item = post.items[idx]
            await api.saveMediaToPhotos(item: item)
        }
        api.toastMessage = "✅ Se guardaron \(selectedIndices.count) archivo(s) en Fotos."
    }
}

// MARK: - Hoja de Login
struct LoginSheetView: View {
    @ObservedObject var api: APIClient
    @Environment(\.dismiss) private var dismiss

    @State private var useCookieTab = false
    @State private var username = ""
    @State private var password = ""
    @State private var code2FA = ""
    @State private var sessionid = ""
    @State private var statusFeedback = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor Cloudflare Conectado") {
                    TextField("https://...", text: $api.serverURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Section("Método de Inicio de Sesión") {
                    Picker("Modo", selection: $useCookieTab) {
                        Text("🔑 Usuario y Clave").tag(false)
                        Text("🍪 Cookie sessionid").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if useCookieTab {
                        TextField("Pega tu cookie sessionid...", text: $sessionid)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    } else {
                        TextField("Usuario de Instagram", text: $username)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        SecureField("Contraseña", text: $password)
                        TextField("Código 2FA (Opcional)", text: $code2FA)
                            .keyboardType(.numberPad)
                    }

                    Button {
                        Task { await submitLogin() }
                    } label: {
                        HStack {
                            if isSubmitting { ProgressView() }
                            Text("Conectar Cuenta de Instagram")
                                .fontWeight(.bold)
                        }
                    }

                    if api.sessionStatus.logged_in {
                        Button("Cerrar Sesión Actual", role: .destructive) {
                            Task {
                                await api.logout()
                                statusFeedback = "Sesión cerrada."
                            }
                        }
                    }

                    if !statusFeedback.isEmpty {
                        Text(statusFeedback)
                            .font(.footnote)
                            .foregroundColor(.pink)
                    }
                }
            }
            .navigationTitle("Sesión de Instagram")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    private func submitLogin() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let payload = useCookieTab
            ? LoginPayload(username: nil, password: nil, verification_code: nil, sessionid: sessionid)
            : LoginPayload(username: username, password: password, verification_code: code2FA.isEmpty ? nil : code2FA, sessionid: nil)
        do {
            let msg = try await api.login(payload: payload)
            statusFeedback = "✅ \(msg)"
            dismiss()
        } catch {
            statusFeedback = "❌ \(error.localizedDescription)"
        }
    }
}
