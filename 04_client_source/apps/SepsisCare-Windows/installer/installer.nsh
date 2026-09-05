; sepsiscare NSIS installer customizations
; Included by electron-builder NSIS target

; --- Custom Install Macro ---
!macro customInstall
  DetailPrint "Configuring SepsisCare local classroom demo..."
  DetailPrint "Default API: http://127.0.0.1:8765"
  DetailPrint "Bundled runtime: Electron app, Windows Python runtime, local API backend, and demo model package."
  DetailPrint "Demo password for research/admin/family roles: 123123"
!macroend

; --- Custom Uninstall Macro ---
!macro customUnInstall
  DetailPrint "Removing SepsisCare..."
  ; Remove legacy firewall rule if an older build created it.
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="sepsiscare Backend"'
  DetailPrint "Legacy local backend firewall rule cleaned up"
  ; Kill any lingering backend processes (python server.py)
  nsExec::ExecToLog 'taskkill /F /IM python.exe /FI "WINDOWTITLE eq *server.py*" 2>nul'
!macroend
