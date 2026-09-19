import SwiftUI

/// 計測パネル。横持ちは Link と Tracking の区画を左右に、縦持ちは上下に並べる。
/// ヘッダーは全幅、本文は左寄せの密な区画（端から端へ引き延ばさない）。
struct ContentView: View {
    @StateObject private var controller = AppController()
    @StateObject private var interfaceOrientation = InterfaceOrientationObserver()
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingName = false
    @State private var nameDraft = ""

    /// ヒートマップの長辺。縦持ちは Link と Tracking の下に積むので、画面の高さに収まるよう小さくする
    private static let heatmapLongLandscape: CGFloat = 200
    private static let heatmapLongPortrait: CGFloat = 160
    private static let panelCorner: CGFloat = 8
    /// 区画のあいだ。広げすぎると視線が飛ぶ
    private static let columnWidth: CGFloat = 268

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
            // iPhone では横持ちのときだけ縦方向の size class が compact になる
            if verticalSizeClass == .compact {
                landscapeBody
            } else {
                portraitBody
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.togglePreview()
        }
        .onAppear {
            interfaceOrientation.start()
            controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                controller.enterForeground()
            case .background:
                controller.enterBackground()
            default:
                break
            }
        }
        .sheet(isPresented: $editingName) {
            nameEditor
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("PocketSensor")
                .font(.system(.title2, design: .default, weight: .semibold))
            if !controller.arkitSupported {
                Text("ARKit 非対応")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .safeAreaPadding(.horizontal, 12)
    }

    private var landscapeBody: some View {
        ZStack(alignment: .topLeading) {
            // Link / Tracking は常に同じ位置。プレビューは右に重ねるだけ
            landscapeColumns
                .padding(.top, 22)
                .padding(.bottom, 16)
                .padding(.leading, 8)
                .padding(.trailing, 20)
                .safeAreaPadding(.horizontal, 12)
            if controller.previewVisible {
                landscapePreview
                    .padding(.top, 22)
                    .padding(.trailing, 20)
                    .safeAreaPadding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 縦持ちは上から積む。プレビューは最後に足すので、開いても Link / Tracking の位置は変わらない
    private var portraitBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            linkColumn
            horizontalRule
            trackingColumn
            if controller.previewVisible {
                horizontalRule
                portraitPreview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .padding(.leading, 8)
        .padding(.trailing, 20)
        .safeAreaPadding(.horizontal, 12)
    }

    private var horizontalRule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 12)
    }

    private var landscapeColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            linkColumn
                .frame(width: Self.columnWidth, alignment: .topLeading)
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)
                .padding(.horizontal, 20)
                .frame(maxHeight: 220)
            trackingColumn
                .frame(width: Self.columnWidth, alignment: .topLeading)
            Spacer(minLength: 0)
        }
    }

    private var linkColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Link")
            VStack(alignment: .leading, spacing: 6) {
                metric("server", serverText)
                metric("bonjour", bonjourText)
                metric("clients", "\(controller.clients)")
                ForEach(controller.linkAddresses, id: \.self) { row in
                    metric(row.name, row.address)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("name")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(controller.deviceName)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("変更") {
                        nameDraft = controller.deviceName
                        editingName = true
                    }
                    .font(.system(.caption))
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var serverText: String {
        if let port = controller.serverPort {
            return "\(controller.serverState)  :\(port)"
        }
        return controller.serverState
    }

    private var bonjourText: String {
        let name = controller.deviceName
        let trimmed = name.count > 18 ? String(name.prefix(16)) + "…" : name
        return "\(trimmed)  _pocketsensor._tcp"
    }

    private var nameEditor: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("端末名", text: $nameDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                } footer: {
                    Text("英小文字で始まり、英小文字・数字・下線だけを使います")
                }
            }
            .navigationTitle("端末名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { editingName = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if controller.setDeviceName(nameDraft) {
                            editingName = false
                        }
                    }
                    .disabled(!controller.isValidDeviceName(nameDraft))
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var trackingColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Tracking")
            Text(controller.tracking)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .foregroundStyle(trackingColor)
                .padding(.top, 2)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 6) {
                metric("pose", String(format: "%.1f Hz", controller.poseHz))
                metric("color", String(format: "%.1f Hz", controller.colorHz))
                metric("depth", controller.depthCenterM.map { String(format: "%.1f Hz  %.2f m", controller.depthHz, $0) } ?? String(format: "%.1f Hz", controller.depthHz))
                metric("imu", String(format: "%.1f Hz", controller.imuHz))
                metric("origin", "\(controller.originEpoch)")
                metric("thermal", controller.thermal)
                metric("battery", controller.batteryText)
            }
            Button("Reset origin") {
                controller.resetOrigin()
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
    }

    private var landscapePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Depth")
            depthHeatmap(long: Self.heatmapLongLandscape)
            poseReadout(width: Self.heatmapLongLandscape)
        }
    }

    /// 縦持ちは高さが足りないので、姿勢の数値はヒートマップの右に置く
    private var portraitPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Depth")
            HStack(alignment: .top, spacing: 12) {
                depthHeatmap(long: Self.heatmapLongPortrait)
                poseReadout(width: nil)
            }
        }
    }

    private var trackingColor: Color {
        switch controller.tracking {
        case "normal": return Color(red: 0.12, green: 0.55, blue: 0.28)
        case let s where s.hasPrefix("limited"): return Color(red: 0.85, green: 0.45, blue: 0.05)
        default: return .primary
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.55))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func depthHeatmap(long: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.panelCorner, style: .continuous)
        let orientation = DepthPreview.displayOrientation(for: interfaceOrientation.current)
        let size = DepthPreview.frameSize(long: long, for: orientation)
        Group {
            if let image = controller.depthPreview {
                Image(uiImage: DepthPreview.reoriented(image, to: orientation))
                    .resizable()
                    .interpolation(.none)
                    .overlay(alignment: .topLeading) {
                        Text("\(DepthPreview.nearM)–\(DepthPreview.farM) m")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(4)
                            .background(.black.opacity(0.45))
                    }
            } else {
                Text("waiting")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.06))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    /// `width` が nil なら文字列の幅に合わせる
    private func poseReadout(width: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(poseText)
            Text(quatText)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(width: width, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Self.panelCorner, style: .continuous))
    }

    private var poseText: String {
        guard let p = controller.position else { return "pos  —" }
        return String(format: "pos  %+.2f %+.2f %+.2f", p.x, p.y, p.z)
    }

    private var quatText: String {
        guard let q = controller.orientation else { return "quat —" }
        let v = q.vector
        return String(format: "quat %+.2f %+.2f %+.2f %+.2f", v.x, v.y, v.z, v.w)
    }
}
