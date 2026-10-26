import SwiftUI
import WebKit
import Photos

@main
struct IGSaverProApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
        }
    }
}

struct ContentView: View {
    @AppStorage("customServerURL") private var customURL: String = "https://tech-innovations-copied-cardiff.trycloudflare.com"
    @State private var showingSettings = false
    @State private var inputURL = ""
    @State private var webViewRef: WKWebView? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebViewContainer(urlString: customURL, webViewRef: $webViewRef)
                .ignoresSafeArea()

            Button(action: {
                inputURL = customURL
                showingSettings = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(10)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .padding(.top, 48)
            .padding(.trailing, 16)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form {
                    Section(header: Text("Servidor Cloudflare / Local")) {
                        TextField("https://tu-tunnel.trycloudflare.com", text: $inputURL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)

                        Button("Restablecer URL por defecto") {
                            inputURL = "https://tech-innovations-copied-cardiff.trycloudflare.com"
                        }

                        Button("Cargar Dashboard Local (Sin servidor)") {
                            inputURL = "local"
                        }
                    }

                    Section(footer: Text("Si tu servidor en PC está apagado o el túnel expiró, puedes usar 'Cargar Dashboard Local' o ingresar la nueva URL de Cloudflare.")) {
                        Button("Guardar y Recargar") {
                            customURL = inputURL
                            showingSettings = false
                            if let webView = webViewRef {
                                if customURL == "local" {
                                    loadLocalHTML(in: webView)
                                } else if let u = URL(string: customURL) {
                                    webView.load(URLRequest(url: u))
                                }
                            }
                        }
                        .fontWeight(.bold)
                    }
                }
                .navigationTitle("Ajustes de Conexión")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { showingSettings = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func loadLocalHTML(in webView: WKWebView) {
        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    let urlString: String
    @Binding var webViewRef: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 11/255, green: 11/255, blue: 16/255, alpha: 1.0)
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        DispatchQueue.main.async {
            self.webViewRef = webView
        }

        loadRequest(in: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func loadRequest(in webView: WKWebView) {
        if urlString == "local" {
            loadLocal(in: webView)
        } else if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        } else {
            loadLocal(in: webView)
        }
    }

    func loadLocal(in webView: WKWebView) {
        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebViewContainer

        init(_ parent: WebViewContainer) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loadLocal(in: webView)
        }
    }
}
