# sepsiscare shared web client

This static client is the shared UI core for the Windows, iOS, and Android ports.

Default cloud API:

```text
http://100.65.136.96:8788
```

Optional local fallback:

```bash
cd apps/sepsiscare-studio/backend
python3 server.py --host 127.0.0.1 --port 8765
```

Then open `apps/sepsiscare-web-client/index.html` in a browser. The default password is `123123`.
This password is a client-side demo gate, not production authentication; remote sensitive APIs still require a Bearer token.
New Windows, iOS, and Android installs use the cloud API by default. Only switch to a loopback/local API when running an offline demo backend.

Packaging wrappers copy this folder into their platform resources:

- Windows: Electron loads `extraResources/web/index.html`.
- iOS: WKWebView loads `Resources/Web/index.html`.
- Android: WebView loads `android_asset/web/index.html`.
