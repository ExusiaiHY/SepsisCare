# 🚀 SepsisCare - Quick Start Guide

**⏱️ 5-Minute Setup** | **✅ Works on macOS & Windows**

---

## For Reviewers/Graders

**Choose your platform**:

### 🍎 macOS (Recommended)

```bash
# One command - install, verify, launch everything
./install_and_verify_macos.command
```

**Or double-click** `install_and_verify_macos.command` in Finder

---

### 🪟 Windows

```powershell
# PowerShell (Run as Administrator)
.\install_and_verify_windows.ps1 -Install -Launch
```

**Or double-click** `install_and_verify_windows.cmd`

---

## 🔑 Demo Login

- **Username**: `researcher` (or `admin` / `family`)
- **Password**: `123123`

---

## 📚 What's Included

| Item | Location |
|------|----------|
| **Final Report** | `01_documentation/03_documentation/SepsisCare_Paper_Report.pdf` |
| **Final Presentation** | `SepsisCare_Final_Presentation.pptx` |
| **macOS App** | `02_installers/sepsiscare-1.0.1-macOS.dmg` |
| **Windows Installer** | `02_installers/windows/sepsiscare-0.9.1-win-x64.exe` |
| **Source Code** | `04_client_source/` |

---

## ✅ Verification Checklist

```
□ Run installation script
□ Login with demo credentials
□ View patient dashboard
□ Check that API responds (http://127.0.0.1:8765/health)
□ Review final report (PDF)
□ Review presentation (PPTX)
```

---

## 🛑 Stop Services

```bash
# macOS
./stop_local_demo.command

# Windows
# Close the app - services stop automatically
```

---

## 📖 Full Documentation

See **`README.md`** for complete details:
- System requirements
- Troubleshooting
- Manual installation
- Developer guide

---

## 💡 Troubleshooting

**Issue**: "Permission denied" on macOS
```bash
chmod +x *.command
./install_and_verify_macos.command
```

**Issue**: Port already in use
```bash
SEPSISCARE_PORT=18765 ./verify_local_demo.command
```

**Issue**: Windows script won't run
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

**🎯 Total Time**: ~5 minutes  
**📦 Package Size**: ~110 MB  
**📅 Last Updated**: June 12, 2026

**✨ Ready for evaluation!**
