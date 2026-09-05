import SwiftUI
import WebKit

struct RootWebView: View {
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://100.65.136.96:8788"
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            SepsisCareWebView(apiBaseURL: apiBaseURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("sepsiscare")
                .toolbar {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        Form {
                            Section("后端 API") {
                                TextField("API 地址", text: $apiBaseURL)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                            }
                            Section("说明") {
                                Text("默认连接 Tailscale 远程 API：http://100.65.136.96:8788。需要本机调试时可临时填写本机或局域网 API 地址。")
                            }
                        }
                        .navigationTitle("设置")
                    }
                }
                .onAppear {
                    if apiBaseURL == "http://127.0.0.1:8765"
                        || apiBaseURL == "http://10.20.197.82:8765"
                        || apiBaseURL == "http://106.55.230.127" {
                        apiBaseURL = "http://100.65.136.96:8788"
                    }
                }
        }
    }
}

struct SepsisCareWebView: UIViewRepresentable {
    let apiBaseURL: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
            webView.loadHTMLString("<h1>Missing Web/index.html</h1><p>Run scripts/sync_sepsiscare_shared_web.sh first.</p>", baseURL: nil)
            return
        }
        var components = URLComponents(url: indexURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: apiBaseURL),
            URLQueryItem(name: "platform", value: "ios")
        ]
        webView.loadFileURL(components?.url ?? indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }
}
