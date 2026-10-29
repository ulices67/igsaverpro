import SwiftUI
import AVFoundation
import AVKit
import WebKit

struct ContentView: View {
    @StateObject private var api = APIClient()
    @State private var searchText = ""
    @State private var searchResults: [SearchUser] = []
    @State private var isSearching = false

    @State private var resolvedProfile: ResolveResponse?
    @State private var profilePosts: [PostItem] = []
    @State private var nextCursor: String = ""
    @State private var directItems: [StoryItem] = []

    // Modal de Destacadas (Item-bound atómico para evitar pantallas en negro)
    @State private var activeHighlightDetail: HighlightDetailResponse?

    // Visor Anónimo de Historias (Item-bound atómico para evitar pantallas en negro)
    @State private var activeStorySession: StoryViewerSession?

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
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedPost) { post in
                PostDetailSheetView(post: post, username: resolvedProfile?.user?.username ?? "user", api: api)
            }
            .sheet(item: $activeHighlightDetail) { hl in
                HighlightExplorerSheetView(
                    highlight: hl,
                    api: api
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $activeStorySession) { session in
                AnonymousStoryPlayerView(
                    session: session,
                    api: api,
                    onClose: { activeStorySession = nil }
                )
            }
            .alert("Aviso", isPresented: Binding(
                get: {
                    activeStorySession == nil &&
                    activeHighlightDetail == nil &&
                    selectedPost == nil &&
                    !showingLoginSheet &&
                    (api.errorMessage != nil || api.toastMessage != nil)
                },
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
                        .fill(!api.isServiceAvailable ? Color.gray : api.sessionStatus.logged_in ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(!api.isServiceAvailable ? "Sin conexión" : api.sessionStatus.logged_in ? "@\(api.sessionStatus.username ?? "Conectado")" : "Iniciar Sesión")
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
                        activeStorySession = StoryViewerSession(
                            items: stories,
                            initialIndex: 0,
                            title: "@\(user.username) · Historias"
                        )
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
                        activeStorySession = StoryViewerSession(
                            items: stories,
                            initialIndex: 0,
                            title: "@\(user.username) · Historias"
                        )
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
                                    SmartThumbnailView(
                                        rawURL: hl.cover_url,
                                        filename: "hl_\(hl.pk).jpg",
                                        api: api
                                    )
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
            ForEach(Array(directItems.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 10) {
                    ZStack {
                        SmartThumbnailView(
                            rawURL: item.thumbnail ?? item.url,
                            filename: "thumb_" + item.filename,
                            api: api,
                            contentMode: .fit
                        )
                        .frame(maxHeight: 360)
                        .cornerRadius(12)

                        if item.media_type == "video" {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.white.opacity(0.9))
                                .shadow(radius: 8)
                        }
                    }
                    .onTapGesture {
                        activeStorySession = StoryViewerSession(
                            items: directItems,
                            initialIndex: index,
                            title: "Vista Previa"
                        )
                    }

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
                let items = res.items ?? []
                directItems = items
                if (res.type == "story" || res.type == "user_stories" || res.type == "highlight"), !items.isEmpty {
                    let uname = res.username ?? "instagram"
                    activeStorySession = StoryViewerSession(
                        items: items,
                        initialIndex: 0,
                        title: "@\(uname) · Historias"
                    )
                }
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
            activeHighlightDetail = detail
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

// MARK: - Miniatura Inteligente con Caché Local (CDN Directo + Respaldo Proxy)
struct SmartThumbnailView: View {
    let rawURL: String
    let filename: String
    @ObservedObject var api: APIClient
    var contentMode: ContentMode = .fill

    @State private var uiImage: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Color.white.opacity(0.08)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    )
            } else {
                Color.white.opacity(0.08)
                    .overlay(ProgressView().tint(.white.opacity(0.7)))
            }
        }
        .task(id: rawURL) {
            guard uiImage == nil else { return }
            failed = false
            if let localURL = try? await api.downloadMediaToCache(rawURL: rawURL, filename: filename, expectVideo: false),
               let decoded = UIImage(contentsOfFile: localURL.path) {
                uiImage = decoded
            } else if !Task.isCancelled {
                failed = true
            }
        }
    }
}

// MARK: - Banner Flotante de Avisos dentro de Modales
struct ModalFeedbackBanner: View {
    @ObservedObject var api: APIClient

    var body: some View {
        if let msg = api.toastMessage ?? api.errorMessage {
            let isError = (api.toastMessage == nil && api.errorMessage != nil)
            Text(msg)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isError ? Color.red.opacity(0.9) : Color.black.opacity(0.85))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .onTapGesture {
                    api.toastMessage = nil
                    api.errorMessage = nil
                }
                .task(id: msg) {
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    if !Task.isCancelled {
                        api.toastMessage = nil
                        api.errorMessage = nil
                    }
                }
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
    @State private var innerStorySession: StoryViewerSession?

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Button {
                            guard !highlight.items.isEmpty else { return }
                            innerStorySession = StoryViewerSession(
                                items: highlight.items,
                                initialIndex: 0,
                                title: "✨ \(highlight.title)"
                            )
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
                                        SmartThumbnailView(
                                            rawURL: item.thumbnail ?? item.url,
                                            filename: "thumb_" + item.filename,
                                            api: api,
                                            contentMode: .fill
                                        )
                                        .frame(height: 190)
                                        .clipped()
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            innerStorySession = StoryViewerSession(
                                                items: highlight.items,
                                                initialIndex: idx,
                                                title: "✨ \(highlight.title)"
                                            )
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

                // Visor integrado sin presentar un segundo UIViewController modal encima del sheet
                if let session = innerStorySession {
                    AnonymousStoryPlayerView(
                        session: session,
                        api: api,
                        onClose: { innerStorySession = nil }
                    )
                    .transition(.opacity)
                    .zIndex(10)
                }

                if innerStorySession == nil {
                    VStack {
                        Spacer()
                        ModalFeedbackBanner(api: api)
                            .padding(.bottom, 16)
                    }
                    .zIndex(15)
                }
            }
            .navigationTitle("✨ \(highlight.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(innerStorySession == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
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

// MARK: - Capa Ligera Nativa AVPlayerLayer (Sin AVPlayerViewController ni Pantalla Negra)
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct StoryAVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

// MARK: - Renderizador Inteligente de Foto/Video para Historias y Destacadas
struct SmartStoryMediaView: View {
    let item: StoryItem
    @ObservedObject var api: APIClient
    let onTapPrev: () -> Void
    let onTapNext: () -> Void

    @State private var loadedImage: UIImage?
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isMuted = false
    @State private var reloadID = UUID()
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            // Vista previa o foto cargada
            if let img = loadedImage, (item.media_type != "video" || player == nil) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(item.media_type == "video" ? 0.65 : 1.0)
            }

            // Reproductor nativo desde archivo .mp4 local en caché
            if item.media_type == "video", let p = player {
                StoryAVPlayerLayerView(player: p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Zonas táctiles izquierda (anterior) y derecha (siguiente)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: geo.size.width * 0.35)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapPrev() }
                    Color.clear
                        .frame(width: geo.size.width * 0.65)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapNext() }
                }
            }

            // Indicador de carga real
            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.3)
                    Text("Cargando historia...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(18)
                .background(Color.black.opacity(0.65))
                .cornerRadius(14)
            }

            // Mensaje de error con botón Reintentar (encima de las zonas táctiles)
            if let err = loadError, !isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button {
                        reloadID = UUID()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Reintentar")
                        }
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.pink)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
                .padding(20)
                .background(Color.black.opacity(0.75))
                .cornerRadius(16)
            }

            // Botón de sonido encima de las zonas táctiles para que siempre responda
            if item.media_type == "video", player != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            isMuted.toggle()
                            player?.isMuted = isMuted
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .padding(11)
                                .background(Color.black.opacity(0.65))
                                .clipShape(Circle())
                        }
                        .padding(16)
                    }
                }
            }
        }
        .task(id: "\(item.id)_\(reloadID.uuidString)") {
            cleanupPlayer()
            loadedImage = nil
            loadError = nil
            isLoading = true

            if item.media_type == "video" {
                if let thumb = item.thumbnail, !thumb.isEmpty, thumb != item.url {
                    if let thumbFile = try? await api.downloadMediaToCache(rawURL: thumb, filename: "thumb_" + item.filename, expectVideo: false),
                       let thumbImg = UIImage(contentsOfFile: thumbFile.path),
                       !Task.isCancelled {
                        self.loadedImage = thumbImg
                    }
                }

                do {
                    let localVideoURL = try await api.downloadMediaToCache(
                        rawURL: item.url,
                        filename: item.filename,
                        expectVideo: true
                    )
                    guard !Task.isCancelled else { return }

                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                    try? AVAudioSession.sharedInstance().setActive(true)

                    let playerItem = AVPlayerItem(url: localVideoURL)
                    let avPlayer = AVPlayer(playerItem: playerItem)
                    avPlayer.isMuted = isMuted
                    avPlayer.actionAtItemEnd = .none

                    let observer = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: playerItem,
                        queue: .main
                    ) { _ in
                        avPlayer.seek(to: .zero)
                        avPlayer.play()
                    }
                    self.endObserver = observer
                    self.player = avPlayer
                    self.isLoading = false
                    avPlayer.play()
                } catch {
                    guard !Task.isCancelled else { return }
                    self.isLoading = false
                    self.loadError = "No se pudo cargar este video. Toca Reintentar."
                }
            } else {
                do {
                    let localImgURL = try await api.downloadMediaToCache(
                        rawURL: item.url,
                        filename: item.filename,
                        expectVideo: false
                    )
                    guard !Task.isCancelled else { return }
                    if let uiImg = UIImage(contentsOfFile: localImgURL.path) {
                        self.loadedImage = uiImg
                        self.isLoading = false
                    } else {
                        self.isLoading = false
                        self.loadError = "No se pudo decodificar la imagen."
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.isLoading = false
                    self.loadError = "No se pudo cargar esta historia. Toca Reintentar."
                }
            }
        }
        .onDisappear {
            cleanupPlayer()
        }
    }

    private func cleanupPlayer() {
        player?.pause()
        player = nil
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
    }
}

// MARK: - Visor Anónimo de Historias (Una por una a pantalla completa, siempre cerrable)
struct AnonymousStoryPlayerView: View {
    let session: StoryViewerSession
    @ObservedObject var api: APIClient
    let onClose: () -> Void

    @State private var currentIndex: Int
    @State private var isSavingCurrent = false

    init(session: StoryViewerSession, api: APIClient, onClose: @escaping () -> Void) {
        self.session = session
        self._api = ObservedObject(wrappedValue: api)
        self.onClose = onClose
        let validIndex = session.items.indices.contains(session.initialIndex) ? session.initialIndex : 0
        _currentIndex = State(initialValue: validIndex)
    }

    var body: some View {
        let items = session.items
        let hasCurrent = items.indices.contains(currentIndex)

        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                // Barras de progreso (siempre visibles arriba)
                if !items.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(items.indices, id: \.self) { idx in
                            Rectangle()
                                .fill(idx <= currentIndex ? Color.pink : Color.white.opacity(0.25))
                                .frame(height: 3)
                                .cornerRadius(2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }

                // Encabezado con botón Cerrar SIEMPRE presente (imposible quedar atrapado)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasCurrent ? "\(session.title) (\(currentIndex + 1)/\(items.count))" : session.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("🕵️‍♂️ Viendo en Modo 100% Anónimo \(hasCurrent ? (items[currentIndex].taken_at ?? "") : "")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 4)

                if hasCurrent {
                    let current = items[currentIndex]

                    SmartStoryMediaView(
                        item: current,
                        api: api,
                        onTapPrev: {
                            if currentIndex > 0 {
                                currentIndex -= 1
                            }
                        },
                        onTapNext: {
                            if currentIndex < items.count - 1 {
                                currentIndex += 1
                            } else {
                                onClose()
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Spacer(minLength: 4)

                    Button {
                        guard !isSavingCurrent else { return }
                        isSavingCurrent = true
                        Task {
                            await api.saveMediaToPhotos(item: current)
                            isSavingCurrent = false
                        }
                    } label: {
                        HStack {
                            if isSavingCurrent {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down.fill")
                            }
                            Text(isSavingCurrent ? "Guardando..." : "Guardar en Fotos")
                        }
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(14)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No hay historias disponibles para mostrar.")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Button("Cerrar", action: onClose)
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.pink)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    Spacer()
                }
            }

            VStack {
                ModalFeedbackBanner(api: api)
                    .padding(.top, 58)
                Spacer()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 40, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.height > 90 && abs(value.translation.height) > abs(value.translation.width) {
                        onClose()
                    }
                }
        )
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

// MARK: - Instagram Web View Representable
struct InstagramWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    var onSessionCaptured: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Observar almacenamiento de cookies de WebKit
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)

        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    }

    static func clearWebCookies(completion: (() -> Void)? = nil) {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            let igRecords = records.filter { record in
                let name = record.displayName.lowercased()
                return name.contains("instagram") || name.contains("facebook") || name.contains("meta")
            }
            if !igRecords.isEmpty {
                dataStore.removeData(ofTypes: types, for: igRecords) {
                    DispatchQueue.main.async { completion?() }
                }
            } else {
                dataStore.removeData(ofTypes: types, modifiedSince: Date.distantPast) {
                    DispatchQueue.main.async { completion?() }
                }
            }
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        var parent: InstagramWebView
        var captured = false

        init(_ parent: InstagramWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            checkCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            checkCookies(in: cookieStore)
        }

        private func checkCookies(in cookieStore: WKHTTPCookieStore) {
            guard !captured else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.captured else { return }
                for cookie in cookies {
                    if cookie.name.lowercased() == "sessionid" {
                        let val = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty && val != "\"\"" {
                            self.captured = true
                            DispatchQueue.main.async {
                                self.parent.onSessionCaptured?(val)
                            }
                            break
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Métodos de Inicio de Sesión
enum LoginMethod: Int, CaseIterable, Identifiable {
    case officialWeb = 0
    case credentials = 1
    case sessionidCookie = 2

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .officialWeb: return "🌐 Web Oficial"
        case .credentials: return "🔑 Usuario/Clave"
        case .sessionidCookie: return "🍪 Cookie"
        }
    }
}

// MARK: - Hoja de Login con Web Oficial de Instagram
struct LoginSheetView: View {
    @ObservedObject var api: APIClient
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMethod: LoginMethod = .officialWeb
    @State private var username = ""
    @State private var password = ""
    @State private var code2FA = ""
    @State private var sessionid = ""
    @State private var statusFeedback = ""
    @State private var isSubmitting = false
    @State private var webIsLoading = true
    @State private var webViewID = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header si ya está conectado
                if api.sessionStatus.logged_in {
                    activeSessionHeader
                }

                // Selector de método
                Picker("Método de Inicio", selection: $selectedMethod) {
                    ForEach(LoginMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                // Contenido según el modo
                Group {
                    switch selectedMethod {
                    case .officialWeb:
                        officialWebLoginView
                    case .credentials:
                        credentialsLoginView
                    case .sessionidCookie:
                        cookieLoginView
                    }
                }

                if !statusFeedback.isEmpty {
                    Text(statusFeedback)
                        .font(.footnote)
                        .foregroundColor(statusFeedback.starts(with: "✅") ? .green : .pink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.07).ignoresSafeArea())
            .navigationTitle("Sesión de Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                        .foregroundColor(.white)
                }
            }
        }
    }

    private var activeSessionHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sesión activa")
                    .font(.caption2)
                    .foregroundColor(.gray)
                Text("@\(api.sessionStatus.username ?? "Conectado")")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            Spacer()
            Button(role: .destructive) {
                Task {
                    await api.logout()
                    InstagramWebView.clearWebCookies {
                        webViewID = UUID()
                    }
                    statusFeedback = "Sesión cerrada correctamente."
                }
            } label: {
                Text("Cerrar Sesión")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.pink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.pink.opacity(0.15))
                    .cornerRadius(8)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var officialWebLoginView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
                Text("instagram.com oficial · Detección automática al entrar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Spacer()
                Button {
                    webIsLoading = true
                    webViewID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                Button {
                    InstagramWebView.clearWebCookies {
                        webIsLoading = true
                        webViewID = UUID()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.pink)
                        .padding(6)
                        .background(Color.pink.opacity(0.15))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)

            ZStack {
                InstagramWebView(
                    url: URL(string: "https://www.instagram.com/accounts/login/")!,
                    isLoading: $webIsLoading,
                    onSessionCaptured: { capturedSessionId in
                        handleCapturedSession(capturedSessionId)
                    }
                )
                .id(webViewID)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 12)

                if webIsLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Cargando Instagram...")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                }

                if isSubmitting {
                    ZStack {
                        Color.black.opacity(0.75).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.3)
                                .tint(.white)
                            Text("¡Sesión de Instagram Detectada!")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Conectando tu cuenta con IG Saver Pro...")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(24)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(red: 0.12, green: 0.12, blue: 0.16))
                        )
                        .shadow(radius: 20)
                    }
                }
            }
        }
    }

    private var credentialsLoginView: some View {
        Form {
            Section {
                TextField("Usuario de Instagram", text: $username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                SecureField("Contraseña", text: $password)
                TextField("Código 2FA (Opcional)", text: $code2FA)
                    .keyboardType(.numberPad)
            } header: {
                Text("Usuario y Contraseña")
            } footer: {
                Text("Si tienes verificación en 2 pasos o Instagram solicita comprobación de seguridad, usa la pestaña 🌐 Web Oficial.")
            }

            Section {
                Button {
                    Task { await submitDirectLogin() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting { ProgressView().padding(.trailing, 4) }
                        Text("Iniciar Sesión")
                            .fontWeight(.bold)
                        Spacer()
                    }
                }
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isSubmitting)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var cookieLoginView: some View {
        Form {
            Section {
                SecureField("Pega tu cookie sessionid...", text: $sessionid)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            } header: {
                Text("Cookie sessionid")
            } footer: {
                Text("Pega la cookie 'sessionid' obtenida desde la versión web de Instagram.")
            }

            Section {
                Button {
                    Task { await submitCookieLogin() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting { ProgressView().padding(.trailing, 4) }
                        Text("Conectar con Cookie")
                            .fontWeight(.bold)
                        Spacer()
                    }
                }
                .disabled(sessionid.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func handleCapturedSession(_ sid: String) {
        guard !isSubmitting else { return }
        isSubmitting = true
        statusFeedback = "Conectando sesión capturada..."
        Task {
            let payload = LoginPayload(username: nil, password: nil, verification_code: nil, sessionid: sid)
            do {
                let msg = try await api.login(payload: payload)
                api.toastMessage = "✅ \(msg)"
                dismiss()
            } catch {
                isSubmitting = false
                statusFeedback = "❌ Error al conectar sesión: \(error.localizedDescription)"
            }
        }
    }

    private func submitDirectLogin() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let payload = LoginPayload(
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            verification_code: code2FA.trimmingCharacters(in: .whitespaces).isEmpty ? nil : code2FA.trimmingCharacters(in: .whitespaces),
            sessionid: nil
        )
        do {
            let msg = try await api.login(payload: payload)
            api.toastMessage = "✅ \(msg)"
            dismiss()
        } catch {
            statusFeedback = "❌ \(error.localizedDescription)"
        }
    }

    private func submitCookieLogin() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let payload = LoginPayload(
            username: nil,
            password: nil,
            verification_code: nil,
            sessionid: sessionid.trimmingCharacters(in: .whitespaces)
        )
        do {
            let msg = try await api.login(payload: payload)
            api.toastMessage = "✅ \(msg)"
            dismiss()
        } catch {
            statusFeedback = "❌ \(error.localizedDescription)"
        }
    }
}
