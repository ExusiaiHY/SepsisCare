import SwiftUI
import AppKit

struct AppBrandColorRole: Identifiable {
    let id: String
    let label: String
    let color: Color
    let usage: String
}

enum AppBrand {
    static let productName = "sepsiscare"
    static let version = "1.0.1"
    static let build = "2026.06.07"
    static let releaseName = "Production Remote Training"
    static let bundleIdentifier = "care.sepsis.desktop"

    static let ink = Color(red: 0.06, green: 0.09, blue: 0.13)
    static let deepNavy = Color(red: 0.04, green: 0.08, blue: 0.14)
    static let midnight = Color(red: 0.02, green: 0.05, blue: 0.10)
    static let clinicalTeal = Color(red: 0.00, green: 0.68, blue: 0.62)
    static let signalBlue = Color(red: 0.10, green: 0.40, blue: 0.98)
    static let oxygenCyan = Color(red: 0.00, green: 0.74, blue: 0.90)
    static let lactateAmber = Color(red: 0.96, green: 0.58, blue: 0.12)
    static let sepsisRed = Color(red: 0.90, green: 0.16, blue: 0.27)
    static let phenotypeViolet = Color(red: 0.46, green: 0.28, blue: 0.92)
    static let recoveryGreen = Color(red: 0.18, green: 0.72, blue: 0.34)
    static let familyMist = Color(red: 0.91, green: 0.98, blue: 0.97)
    static let familyAqua = Color(red: 0.10, green: 0.66, blue: 0.72)
    static let adminGold = Color(red: 1.00, green: 0.70, blue: 0.22)
    static let chartMagenta = Color(red: 0.95, green: 0.25, blue: 0.56)

    static let colorRoles: [AppBrandColorRole] = [
        AppBrandColorRole(id: "neutralContext", label: "中性背景", color: Color.primary.opacity(0.60), usage: "文本、分隔线、非焦点状态"),
        AppBrandColorRole(id: "primaryAction", label: "主操作", color: signalBlue, usage: "研究端主要入口、链接和选中态"),
        AppBrandColorRole(id: "comparison", label: "对照曲线", color: oxygenCyan, usage: "预测曲线、实时趋势和对照指标"),
        AppBrandColorRole(id: "warning", label: "观察预警", color: lactateAmber, usage: "乳酸、通气风险和待巡检状态"),
        AppBrandColorRole(id: "critical", label: "危重告警", color: sepsisRed, usage: "死亡风险、休克提示和异常检查"),
        AppBrandColorRole(id: "recovery", label: "恢复稳定", color: recoveryGreen, usage: "稳定患者、恢复趋势和通过检查"),
        AppBrandColorRole(id: "family", label: "家属端", color: familyAqua, usage: "家属门户、低密度解释和沟通视图"),
        AppBrandColorRole(id: "admin", label: "管理员端", color: adminGold, usage: "服务巡检、账号绑定和运维状态")
    ]

    static var brandManifestURL: URL? {
        Bundle.module.url(forResource: "brand_manifest", withExtension: "json", subdirectory: "Brand")
            ?? Bundle.module.url(forResource: "brand_manifest", withExtension: "json")
    }

    static var logoSVGURL: URL? {
        Bundle.module.url(forResource: "sepsiscare-logo", withExtension: "svg", subdirectory: "Brand")
            ?? Bundle.module.url(forResource: "sepsiscare-logo", withExtension: "svg")
    }

    static func accent(for role: UserRole) -> Color {
        switch role {
        case .research: return signalBlue
        case .family: return familyAqua
        case .admin: return adminGold
        }
    }

    static func configureApplicationIcon() {
        NSApplication.shared.applicationIconImage = makeApplicationIcon(size: 512)
    }

    private static func makeApplicationIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let radius = size * 0.21
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.035, dy: size * 0.035), xRadius: radius, yRadius: radius)
        NSGradient(colors: [
            NSColor(red: 0.02, green: 0.06, blue: 0.13, alpha: 1),
            NSColor(red: 0.00, green: 0.42, blue: 0.50, alpha: 1),
            NSColor(red: 0.08, green: 0.25, blue: 0.72, alpha: 1)
        ])?.draw(in: path, angle: 315)

        NSColor.white.withAlphaComponent(0.18).setStroke()
        let grid = NSBezierPath()
        for step in stride(from: size * 0.18, through: size * 0.82, by: size * 0.16) {
            grid.move(to: NSPoint(x: step, y: size * 0.16))
            grid.line(to: NSPoint(x: step, y: size * 0.84))
            grid.move(to: NSPoint(x: size * 0.16, y: step))
            grid.line(to: NSPoint(x: size * 0.84, y: step))
        }
        grid.lineWidth = size * 0.004
        grid.stroke()

        let cross = NSBezierPath()
        let center = size * 0.5
        let arm = size * 0.105
        let long = size * 0.25
        cross.appendRect(NSRect(x: center - arm / 2, y: center - long / 2, width: arm, height: long))
        cross.appendRect(NSRect(x: center - long / 2, y: center - arm / 2, width: long, height: arm))
        NSColor.white.withAlphaComponent(0.92).setFill()
        cross.fill()

        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: size * 0.16, y: size * 0.36))
        wave.line(to: NSPoint(x: size * 0.29, y: size * 0.36))
        wave.line(to: NSPoint(x: size * 0.36, y: size * 0.50))
        wave.line(to: NSPoint(x: size * 0.43, y: size * 0.25))
        wave.line(to: NSPoint(x: size * 0.52, y: size * 0.67))
        wave.line(to: NSPoint(x: size * 0.61, y: size * 0.36))
        wave.line(to: NSPoint(x: size * 0.84, y: size * 0.36))
        NSColor(red: 0.00, green: 0.86, blue: 0.78, alpha: 1).setStroke()
        wave.lineWidth = size * 0.035
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        wave.stroke()

        image.unlockFocus()
        return image
    }
}

struct BrandLogoMark: View {
    var size: CGFloat = 44
    var showsPulse = true

    var body: some View {
        ZStack {
            if showsPulse {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(AppBrand.oxygenCyan.opacity(0.26), lineWidth: max(1, size * 0.018))
                    .scaleEffect(1.12)
                    .blur(radius: size * 0.03)
            }

            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppBrand.midnight, AppBrand.clinicalTeal.opacity(0.92), AppBrand.signalBlue, AppBrand.phenotypeViolet.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: max(1, size * 0.025))
                }

            Path { path in
                for step in stride(from: size * 0.22, through: size * 0.78, by: size * 0.19) {
                    path.move(to: CGPoint(x: step, y: size * 0.18))
                    path.addLine(to: CGPoint(x: step, y: size * 0.82))
                    path.move(to: CGPoint(x: size * 0.18, y: step))
                    path.addLine(to: CGPoint(x: size * 0.82, y: step))
                }
            }
            .stroke(.white.opacity(0.10), lineWidth: max(0.6, size * 0.012))

            Path { path in
                let w = size
                path.move(to: CGPoint(x: w * 0.17, y: w * 0.57))
                path.addLine(to: CGPoint(x: w * 0.31, y: w * 0.57))
                path.addLine(to: CGPoint(x: w * 0.38, y: w * 0.42))
                path.addLine(to: CGPoint(x: w * 0.46, y: w * 0.70))
                path.addLine(to: CGPoint(x: w * 0.56, y: w * 0.26))
                path.addLine(to: CGPoint(x: w * 0.66, y: w * 0.57))
                path.addLine(to: CGPoint(x: w * 0.84, y: w * 0.57))
            }
            .stroke(AppBrand.oxygenCyan, style: StrokeStyle(lineWidth: max(2, size * 0.07), lineCap: .round, lineJoin: .round))
            .shadow(color: AppBrand.oxygenCyan.opacity(0.55), radius: size * 0.08)

            Image(systemName: "cross.fill")
                .font(.system(size: size * 0.30, weight: .black))
                .foregroundStyle(.white.opacity(0.92))
                .offset(y: -size * 0.13)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("sepsiscare logo")
    }
}

struct BrandVersionPill: View {
    var compact = false

    var body: some View {
        Text(compact ? "v\(AppBrand.version)" : "v\(AppBrand.version) · \(AppBrand.releaseName)")
            .font(.system(size: compact ? 10 : 11, weight: .bold, design: .monospaced))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 6)
            .background(AppBrand.signalBlue.opacity(0.13))
            .foregroundStyle(AppBrand.oxygenCyan)
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AppBrand.oxygenCyan.opacity(0.20), lineWidth: 1)
            }
    }
}

enum BrandBackdropStyle {
    case login
    case research
    case family
    case admin
    case docs
}

struct BrandPatternBackdrop: View {
    var style: BrandBackdropStyle = .research
    var intensity: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Path { path in
                    let spacing: CGFloat = 34
                    for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(gridColor.opacity(0.050 * intensity), lineWidth: 1)

                Path { path in
                    let spacing: CGFloat = 118
                    for x in stride(from: -spacing, through: size.width + spacing, by: spacing) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height * 0.44, y: size.height))
                    }
                }
                .stroke(accentColor.opacity(0.035 * intensity), lineWidth: 1.2)

                Path { path in
                    let y = size.height * 0.68
                    path.move(to: CGPoint(x: size.width * 0.05, y: y))
                    path.addLine(to: CGPoint(x: size.width * 0.22, y: y))
                    path.addLine(to: CGPoint(x: size.width * 0.28, y: y - 34))
                    path.addLine(to: CGPoint(x: size.width * 0.34, y: y + 46))
                    path.addLine(to: CGPoint(x: size.width * 0.43, y: y - 70))
                    path.addLine(to: CGPoint(x: size.width * 0.52, y: y))
                    path.addLine(to: CGPoint(x: size.width * 0.82, y: y))
                    path.addLine(to: CGPoint(x: size.width * 0.88, y: y - 22))
                    path.addLine(to: CGPoint(x: size.width * 0.94, y: y))
                }
                .stroke(accentColor.opacity(0.17 * intensity), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        BrandLogoMark(size: min(size.width, size.height) * 0.28, showsPulse: false)
                            .opacity(watermarkOpacity)
                            .rotationEffect(.degrees(-8))
                            .offset(x: 26, y: 18)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private var gradientColors: [Color] {
        switch style {
        case .family:
            return [
                Color.white,
                AppBrand.familyMist,
                Color(red: 0.84, green: 0.95, blue: 1.00),
                Color(red: 0.96, green: 1.00, blue: 0.98)
            ]
        case .admin:
            return [
                Color(red: 0.05, green: 0.05, blue: 0.07),
                Color(red: 0.10, green: 0.08, blue: 0.13),
                AppBrand.phenotypeViolet.opacity(0.30),
                Color(red: 0.09, green: 0.08, blue: 0.05)
            ]
        case .docs:
            return [AppBrand.midnight, AppBrand.deepNavy, AppBrand.ink]
        case .login, .research:
            return [
                AppBrand.midnight,
                AppBrand.deepNavy,
                AppBrand.clinicalTeal.opacity(0.32),
                AppBrand.ink
            ]
        }
    }

    private var accentColor: Color {
        switch style {
        case .family: return AppBrand.familyAqua
        case .admin: return AppBrand.adminGold
        case .docs: return AppBrand.oxygenCyan
        case .login, .research: return AppBrand.oxygenCyan
        }
    }

    private var gridColor: Color {
        switch style {
        case .family: return AppBrand.familyAqua
        case .admin: return AppBrand.adminGold
        case .docs, .login, .research: return AppBrand.oxygenCyan
        }
    }

    private var watermarkOpacity: Double {
        switch style {
        case .family: return 0.045 * intensity
        case .admin: return 0.060 * intensity
        case .docs: return 0.045 * intensity
        case .login, .research: return 0.055 * intensity
        }
    }
}
