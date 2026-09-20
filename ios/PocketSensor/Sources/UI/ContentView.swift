import PocketSensorCore
import SwiftUI
import UIKit

/// 配信している値を人が確かめる計器盤。数値は 5 Hz の snapshot。
///
/// 数値は 7 字セルを空白で右寄せした固定幅文字列。frame で切らず、字幅で揃える。
/// footnote 相当 12 pt モノスペースの 0.6 em は 7.2 pt/字。
/// quat 4 セル + 間隔 1 字 × 3 = 31 字 × 7.2 = 223.2 pt。ラベル 52 + 間隔 6 = 281.2 pt。300 pt に収まる。
struct ContentView: View {
    @StateObject private var controller = AppController()
    @StateObject private var interfaceOrientation = InterfaceOrientationObserver()
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var showingSettings = ProcessInfo.processInfo.arguments.contains("-PocketSensorDemoSettings")

    // iPhone 16 Pro 横幅 874 pt。横向きのシステム safe area は左 59（Dynamic Island）+ 右 34（ホームインジケータ）。
    // landscapeBody はさらに padding 8+16 と safeAreaPadding 12+16。本文幅 874-59-34-8-16-12-16 = 729。
    // 仕切りは 1 + 水平 padding 12×2 = 25。右列は (729-25)/2 = 352。
    // 長辺 140 のタイル 2 枚 + 間隔 8 = 288 で、352 に収まる。
    private static let previewLongLandscape: CGFloat = 140
    // 縦向きは 90° 回して 126×168。2 枚 + 間隔 8 = 260 pt。
    // iPhone 16 Pro 幅 402。左右 padding 8+16 と safeAreaPadding 12+12 = 48。本文 354。260 は収まる。
    private static let previewLongPortrait: CGFloat = 168
    private static let previewTileSpacing: CGFloat = 8
    private static let panelCorner: CGFloat = 8
    private static let labelWidth: CGFloat = 52
    private static let valueSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
            if verticalSizeClass == .compact {
                landscapeBody
            } else {
                portraitBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("PocketSensor")
                .font(.system(.title2, design: .default, weight: .semibold))
            if !controller.arkitSupported {
                Text("ARKit 非対応")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("設定")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .safeAreaPadding(.horizontal, 12)
    }

    private var landscapeBody: some View {
        HStack(alignment: .top, spacing: 0) {
            columnScroll {
                poseColumn
                horizontalRule
                imuColumn
            }
            columnDivider
            columnScroll {
                if controller.previewVisible {
                    rgbdSection(long: Self.previewLongLandscape)
                    horizontalRule
                }
                linkColumn
                horizontalRule
                environmentColumn
                horizontalRule
                streamsColumn
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .safeAreaPadding(.leading, 12)
        .safeAreaPadding(.trailing, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.togglePreview()
        }
    }

    private var portraitBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                linkColumn
                horizontalRule
                poseColumn
                if controller.previewVisible {
                    horizontalRule
                    rgbdSection(long: Self.previewLongPortrait)
                }
                horizontalRule
                imuColumn
                horizontalRule
                environmentColumn
                horizontalRule
                streamsColumn
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .safeAreaPadding(.horizontal, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            controller.togglePreview()
        }
    }

    private var metricSpacing: CGFloat {
        verticalSizeClass == .compact ? 3 : 4
    }

    private var sectionSpacing: CGFloat {
        verticalSizeClass == .compact ? 4 : 6
    }

    private var horizontalRule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, verticalSizeClass == .compact ? 6 : 8)
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
    }

    private func columnScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var linkColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            sectionTitle("Link")
            VStack(alignment: .leading, spacing: metricSpacing) {
                envValue(serverClientsText)
                ForEach(controller.linkAddresses, id: \.self) { row in
                    envValue("\(row.name)  \(row.address)")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(controller.deviceName)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("変更") {
                        nameDraft = controller.deviceName
                        editingName = true
                    }
                    .font(.system(.caption2))
                    .buttonStyle(.borderless)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var serverClientsText: String {
        let server: String
        if let port = controller.serverPort {
            server = "\(controller.serverState) :\(port)"
        } else {
            server = controller.serverState
        }
        return "server \(server)   clients \(controller.clients)"
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

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("OFF にした区画のセンサーは、受け手が購読したときだけ動きます。")
                }
                Section {
                    Toggle("Pose を表示", isOn: displayBinding(\.pose))
                } footer: {
                    Text("購読が無くても ARKit を動かします。発熱と消費電力が増えます。")
                }
                Section {
                    Toggle("IMU を表示", isOn: displayBinding(\.imu))
                } footer: {
                    Text("購読が無くても IMU と地磁気を取得します。")
                }
                Section {
                    Toggle("環境を表示", isOn: displayBinding(\.environment))
                } footer: {
                    Text("購読が無くても気圧と電池を取得します。")
                }
                Section {
                    Toggle("GNSS を表示", isOn: displayBinding(\.gnss))
                } footer: {
                    Text("購読が無くても測位します。最初に位置情報の許可を求めます。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showingSettings = false }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func displayBinding(_ keyPath: WritableKeyPath<DisplaySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.displaySettings[keyPath: keyPath] },
            set: { value in
                var next = controller.displaySettings
                next[keyPath: keyPath] = value
                controller.setDisplaySettings(next)
            }
        )
    }

    private var poseColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionTitle("Pose")
                Spacer(minLength: 0)
                Text(controller.snapshot.tracking)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(trackingColor)
                Button("Reset origin") {
                    controller.resetOrigin()
                }
                .font(.system(.caption2))
                .buttonStyle(.borderless)
            }
            axisHeader(["x", "y", "z"])
            vectorRow("pos", Readout.vectorCells(controller.snapshot.positionM, fractionDigits: 2), unit: "m")
            vectorRow("rpy", Readout.rpyCells(controller.snapshot.poseRPYDeg), unit: "deg")
            axisHeader(["x", "y", "z", "w"])
            vectorRow("quat", Readout.quaternionCells(controller.snapshot.orientation), unit: "")
            envRow("origin", "\(controller.snapshot.originEpoch)")
        }
    }

    private var imuColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            sectionTitle("IMU")
            axisHeader(["x", "y", "z"])
            vectorRow("accel", Readout.vectorCells(controller.snapshot.specificForceMps2, fractionDigits: 2), unit: "m/s2")
            vectorRow("gyro", Readout.vectorCells(controller.snapshot.angularVelocityRadS, fractionDigits: 3), unit: "rad/s")
            vectorRow("rpy", Readout.rpyCells(controller.snapshot.imuRPYDeg), unit: "deg")
            vectorRow(
                "mag",
                Readout.vectorCells(controller.snapshot.magneticFieldUT, fractionDigits: 1),
                unit: "uT",
                trailing: controller.snapshot.magCalibration.rawValue
            )
        }
    }

    private var environmentColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            sectionTitle("Environment")
            VStack(alignment: .leading, spacing: metricSpacing) {
                envRow(
                    "press",
                    Readout.pressureAltitudeLine(
                        pa: controller.snapshot.pressurePa,
                        relativeAltitudeM: controller.snapshot.relativeAltitudeM
                    )
                )
                if let latlon = Readout.gnssLatLon(
                    latitude: controller.snapshot.gnssLatitude,
                    longitude: controller.snapshot.gnssLongitude
                ), let acc = controller.snapshot.gnssHorizontalAccuracyM, acc >= 0 {
                    envRow("gnss", latlon)
                    envRow(
                        "acc",
                        Readout.gnssAccuracyLine(horizontalM: acc, altitudeM: controller.snapshot.gnssAltitudeM)
                    )
                } else {
                    envRow(
                        "gnss",
                        Readout.gnss(
                            latitude: controller.snapshot.gnssLatitude,
                            longitude: controller.snapshot.gnssLongitude,
                            horizontalAccuracyM: controller.snapshot.gnssHorizontalAccuracyM,
                            authorization: controller.snapshot.locationAuthorization
                        )
                    )
                }
                envRow(
                    "batt",
                    Readout.batteryThermal(
                        level: controller.snapshot.batteryLevel,
                        state: controller.snapshot.batteryState,
                        thermal: controller.snapshot.thermal
                    )
                )
                envRow("clock", Readout.clock(controller.snapshot.clock))
            }
        }
    }

    private var streamsColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            sectionTitle("Streams")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8, alignment: .leading),
                    GridItem(.flexible(), spacing: 8, alignment: .leading),
                ],
                alignment: .leading,
                spacing: metricSpacing
            ) {
                ForEach(Readout.streamPanelRows, id: \.label) { row in
                    streamCell(row)
                }
            }
        }
    }

    private func streamCell(_ row: (label: String, keys: [String])) -> some View {
        let hz = Readout.combinedRateHz(keys: row.keys, rates: controller.snapshot.ratesHz)
        let drops = Readout.combinedDrops(keys: row.keys, drops: controller.snapshot.drops)
        return HStack(spacing: 4) {
            Text(Readout.streamRate(label: row.label, hz: hz))
                .font(.system(size: Self.valueSize, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
            if let drop = Readout.streamDrop(drops) {
                Text(drop)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }

    private func rgbdSection(long: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("RGB-D")
            rgbdTiles(preferredLong: long)
            Text(
                controller.snapshot.depthCenterM.map { String(format: "center  %.2f m", $0) }
                    ?? "center  \(Readout.missing)"
            )
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private var trackingColor: Color {
        switch controller.snapshot.tracking {
        case "normal": return Color(red: 0.12, green: 0.55, blue: 0.28)
        case let s where s.hasPrefix("limited"): return Color(red: 0.85, green: 0.45, blue: 0.05)
        case "off": return .secondary
        default: return .primary
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.55))
    }

    private func axisHeader(_ axes: [String]) -> some View {
        let padded = axes.map { axis in
            String(repeating: " ", count: max(0, Readout.cellWidth - axis.count)) + axis
        }.joined(separator: " ")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear.frame(width: Self.labelWidth, height: 1)
            Text(padded)
                .font(.system(size: Self.valueSize, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func vectorRow(_ label: String, _ cells: [String], unit: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            Text(cells.joined(separator: " "))
                .font(.system(size: Self.valueSize, design: .monospaced))
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if let trailing {
                Text(trailing)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }

    private func envRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            envValue(value)
        }
    }

    private func envValue(_ value: String) -> some View {
        Text(value)
            .font(.system(size: Self.valueSize, design: .monospaced))
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func rgbdTiles(preferredLong: CGFloat) -> some View {
        let orientation = DepthPreview.displayOrientation(for: interfaceOrientation.current)
        RGBDTileLayout(
            preferredLong: preferredLong,
            orientation: orientation,
            spacing: Self.previewTileSpacing
        ) {
            previewTile(
                image: controller.preview?.rgb,
                orientation: orientation,
                interpolation: .medium,
                overlay: "rgb"
            )
            previewTile(
                image: controller.preview?.depth,
                orientation: orientation,
                interpolation: .none,
                overlay: String(format: "%.2f–%.1f m", DepthPreview.nearM, DepthPreview.farM)
            )
        }
    }

    @ViewBuilder
    private func previewTile(
        image: UIImage?,
        orientation: UIImage.Orientation,
        interpolation: Image.Interpolation,
        overlay: String
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.panelCorner, style: .continuous)
        Group {
            if let image {
                Image(uiImage: DepthPreview.reoriented(image, to: orientation))
                    .resizable()
                    .interpolation(interpolation)
                    .overlay(alignment: .topLeading) {
                        Text(overlay)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

/// 2 枚のタイルを同じ大きさで横に並べる。幅が足りなければ `fittedLong` で長辺を縮める。
private struct RGBDTileLayout: Layout {
    var preferredLong: CGFloat
    var orientation: UIImage.Orientation
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .greatestFiniteMagnitude
        let tile = tileSize(availableWidth: available)
        let count = CGFloat(subviews.count)
        let gaps = max(count - 1, 0)
        return CGSize(width: tile.width * count + spacing * gaps, height: tile.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let tile = tileSize(availableWidth: bounds.width)
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: tile.width, height: tile.height)
            )
            x += tile.width + spacing
        }
    }

    private func tileSize(availableWidth: CGFloat) -> CGSize {
        let long = DepthPreview.fittedLong(
            preferred: preferredLong,
            availableWidth: availableWidth,
            spacing: spacing,
            for: orientation
        )
        return DepthPreview.frameSize(long: long, for: orientation)
    }
}
