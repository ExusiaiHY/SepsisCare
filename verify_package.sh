#!/bin/bash
# Package verification script

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║     SepsisCare Final Delivery - Package Verification         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0

check_file() {
    if [ -f "$1" ]; then
        echo "✓ $2"
        ((PASS++))
    else
        echo "✗ $2 - MISSING"
        ((FAIL++))
    fi
}

check_exec() {
    if [ -x "$1" ]; then
        echo "✓ $2 (executable)"
        ((PASS++))
    else
        echo "✗ $2 - NOT EXECUTABLE"
        ((FAIL++))
    fi
}

check_dir() {
    if [ -d "$1" ]; then
        echo "✓ $2"
        ((PASS++))
    else
        echo "✗ $2 - MISSING"
        ((FAIL++))
    fi
}

echo "📋 Checking Core Documentation..."
check_file "README.md" "README.md"
check_file "QUICK_START.md" "Quick Start Guide"
check_file "VERIFICATION_CHECKLIST.md" "Verification Checklist"
check_file "PACKAGE_MANIFEST.md" "Package Manifest"
check_file "SHA256SUMS.txt" "SHA256 Checksums"
echo ""

echo "📄 Checking Academic Documents..."
check_file "SepsisCare_Final_Presentation.pptx" "Final Presentation (root)"
check_file "01_documentation/03_documentation/SepsisCare_Paper_Report.pdf" "Final Report"
check_file "01_documentation/03_documentation/SepsisCare_Final_Presentation.pptx" "Presentation (docs)"
echo ""

echo "💿 Checking Installers..."
check_file "02_installers/sepsiscare-1.0.1-macOS.dmg" "macOS DMG Installer"
check_file "02_installers/windows/sepsiscare-0.9.1-win-x64.exe" "Windows EXE Installer"
echo ""

echo "🚀 Checking Scripts..."
check_exec "install_and_verify_macos.command" "macOS Install Script"
check_file "install_and_verify_windows.ps1" "Windows PowerShell Script"
check_file "install_and_verify_windows.cmd" "Windows CMD Script"
check_exec "start_local_demo.command" "Start Demo Script"
check_exec "stop_local_demo.command" "Stop Demo Script"
check_exec "verify_local_demo.command" "Verify Demo Script"
check_exec "tools/sepsiscare_demo_control.sh" "Master Control Script"
echo ""

echo "🖥️ Checking Directories..."
check_dir "03_remote_server_model_package" "Server Model Package"
check_dir "04_client_source" "Client Source Code"
check_dir "05_quality_security" "Security & Quality"
check_dir "06_scripts" "Scripts & Utilities"
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"

if [ $FAIL -eq 0 ]; then
    echo "✅ Package verification PASSED - All files present!"
    exit 0
else
    echo "❌ Package verification FAILED - $FAIL items missing!"
    exit 1
fi
