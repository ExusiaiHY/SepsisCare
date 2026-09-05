# ✅ SepsisCare Delivery Verification Checklist

**For Course Graders & Reviewers**

Date: June 12, 2026  
Package Version: 1.0.1

---

## 📋 Pre-Verification

- [ ] Package extracted successfully
- [ ] README.md is readable and complete
- [ ] QUICK_START.md is present
- [ ] SHA256SUMS.txt exists

---

## 🎯 Core Deliverables (Required)

### 1. Documentation

- [ ] **Final Report** exists at `01_documentation/03_documentation/SepsisCare_Paper_Report.pdf`
  - File size: ~8.4 MB
  - SHA256: `47b52ef62c5bd60c150f573bb35a87cd921461868d5ea86d816f6e74010c2eff`
  - Opens correctly
  - Contains all required sections (Introduction, Methods, Results, Discussion)

- [ ] **Final Presentation** exists at root `SepsisCare_Final_Presentation.pptx`
  - File size: ~9.6 MB
  - SHA256: `490acda60d64d5747e3c6ef5ad1607c228a2567c8b039db016521961fe8e9def`
  - Opens correctly
  - Contains ~40 slides

- [ ] **Installation Guide** exists at `01_documentation/03_documentation/SepsisCare_Installation_Guide.ipynb`
  - Jupyter notebook format
  - Contains setup instructions

### 2. Working Software

#### macOS Installer
- [ ] File: `02_installers/sepsiscare-1.0.1-macOS.dmg`
  - File size: ~2.7 MB
  - SHA256: `28d69bab5cf48a995c1fc1dd8d12c0b81656736cffc77d57c1c5c2c356a3ad38`
  - DMG mounts successfully
  - App can be copied to Applications

#### Windows Installer
- [ ] File: `02_installers/windows/sepsiscare-0.9.1-win-x64.exe`
  - File size: ~91 MB
  - SHA256: `cf74cd814c05d3c8586275d5a7a03f3343e366665df12934323b35c30112c859`
  - Installer launches (requires Windows to verify)

### 3. One-Click Deployment Scripts

#### macOS
- [ ] `install_and_verify_macos.command` exists
- [ ] Script is executable (`chmod +x`)
- [ ] Script runs without errors
- [ ] Installs app successfully
- [ ] Starts local services
- [ ] Runs verification tests
- [ ] All tests pass

#### Windows
- [ ] `install_and_verify_windows.ps1` exists
- [ ] `install_and_verify_windows.cmd` exists
- [ ] Scripts execute (requires Windows to verify)

### 4. Source Code

- [ ] `04_client_source/` directory exists
- [ ] Contains macOS source (`SepsisCare-macOS/`)
- [ ] Contains Windows source (`apps/SepsisCare-Windows/`)
- [ ] Contains Android source (`apps/SepsisCare-Android/`)
- [ ] Contains iOS source (`apps/SepsisCare-iOS/`)
- [ ] Contains Web client (`apps/sepsiscare-studio/`)

### 5. Detailed README

- [ ] Root `README.md` is complete (>200 lines)
- [ ] Contains table of contents
- [ ] Includes installation instructions for both platforms
- [ ] Contains troubleshooting section
- [ ] Includes system requirements
- [ ] Has verification checklist
- [ ] Formatting is clear and professional

---

## 🧪 Functional Testing (macOS)

### Installation
- [ ] Run `./install_and_verify_macos.command`
- [ ] Script completes without errors
- [ ] App installed to `~/Applications/SepsisCare-macOS.app`
- [ ] Local API starts on port 8765
- [ ] Model service starts on port 8788

### Application Launch
- [ ] App launches successfully
- [ ] Login screen appears
- [ ] Can login with demo credentials:
  - Username: `researcher`
  - Password: `123123`
- [ ] Dashboard loads with patient data

### Core Features
- [ ] Can view patient list
- [ ] Can select a patient
- [ ] Vital signs display correctly
- [ ] Predictions are shown
- [ ] Real-time monitoring works
- [ ] Alerts are visible
- [ ] Export function works

### API Verification
- [ ] Health endpoint responds: `curl http://127.0.0.1:8765/health`
- [ ] Returns `200 OK`
- [ ] Model endpoint responds: `curl http://127.0.0.1:8788/predict`
- [ ] Returns valid prediction

### Cleanup
- [ ] Run `./stop_local_demo.command`
- [ ] Services stop cleanly
- [ ] No error messages

---

## 🪟 Functional Testing (Windows)

### Installation
- [ ] Run `.\install_and_verify_windows.ps1 -Install`
- [ ] Installer completes successfully
- [ ] App appears in Start Menu
- [ ] Shortcuts created on Desktop (if selected)

### Application Launch
- [ ] App launches from Start Menu
- [ ] Login screen appears
- [ ] Can login with demo credentials
- [ ] Dashboard loads

### Core Features
- [ ] Patient list displays
- [ ] Can navigate to patient details
- [ ] Vitals and predictions show
- [ ] Export works

---

## 📊 Quality Checks

### Security & Compliance
- [ ] `05_quality_security/` directory exists
- [ ] Contains security review document
- [ ] Contains deployment report
- [ ] Security audit outputs present

### Code Quality
- [ ] Source code is well-organized
- [ ] README files in subdirectories
- [ ] Build scripts present
- [ ] Dependencies documented

### Documentation Quality
- [ ] All PDFs open correctly
- [ ] PPTX opens correctly
- [ ] LaTeX source files included
- [ ] Figures directory present
- [ ] All references are complete

---

## 🔍 Integrity Verification

### Checksums
- [ ] Run: `shasum -c SHA256SUMS.txt`
- [ ] All checksums match
- [ ] No files corrupted

### Package Completeness
```bash
# Expected directory structure
SepsisCare_Final_Submission_20260612/
├── README.md                          ✓
├── QUICK_START.md                     ✓
├── SHA256SUMS.txt                     ✓
├── SepsisCare_Final_Presentation.pptx ✓
├── 01_documentation/                  ✓
├── 02_installers/                     ✓
├── 03_remote_server_model_package/    ✓
├── 04_client_source/                  ✓
├── 05_quality_security/               ✓
├── 06_scripts/                        ✓
├── tools/                             ✓
└── *.command / *.ps1 scripts          ✓
```

---

## 📝 Grading Rubric Match

### Required Components (100%)

| Component | Weight | Status |
|-----------|--------|--------|
| Working Software (Both Platforms) | 30% | [ ] |
| One-Click Deployment | 15% | [ ] |
| Final Report | 20% | [ ] |
| Final Presentation | 15% | [ ] |
| Detailed README | 10% | [ ] |
| Source Code | 5% | [ ] |
| Verification Scripts | 5% | [ ] |

---

## ✅ Final Sign-Off

### Evaluator Information
- **Name**: _____________________
- **Date**: _____________________
- **Platform Tested**: [ ] macOS [ ] Windows [ ] Both

### Overall Assessment
- [ ] All deliverables present
- [ ] Software runs correctly
- [ ] Documentation is complete
- [ ] Installation is straightforward
- [ ] README is professional and detailed

### Issues Found (if any)
```
_________________________________________________________________
_________________________________________________________________
_________________________________________________________________
```

### Recommendation
- [ ] **PASS** - All requirements met
- [ ] **CONDITIONAL PASS** - Minor issues (specify above)
- [ ] **NEEDS REVISION** - Major issues (specify above)

---

## 📌 Quick Test (2 Minutes)

**Fastest way to verify everything works**:

```bash
# macOS
./install_and_verify_macos.command

# Check these 3 things:
1. Script completes without errors
2. App launches and shows login
3. Can login and see dashboard
```

If all three work → **Software is functional** ✅

---

## 📧 Contact for Issues

If you encounter any problems during evaluation, check:
1. Logs in `.sepsiscare-runtime/logs/`
2. Troubleshooting section in README.md
3. Installation Guide Jupyter notebook

---

**Last Updated**: June 12, 2026  
**Checklist Version**: 1.0  
**Package Version**: 1.0.1
