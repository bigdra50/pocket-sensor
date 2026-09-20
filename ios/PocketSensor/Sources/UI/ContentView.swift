import PocketSensorCore
import SwiftUI

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

    private static let heatmapLongLandscape: CGFloat = 140
    private static let heatmapLongPortrait: CGFloat = 120
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
                    depthSection(long: Self.heatmapLongLandscape)
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
    }

    private var portraitBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                linkColumn
                horizontalRule
                poseColumn
                if controller.previewVisible {
                    horizontalRule
                    depthSection(long: Self.heatmapLongPortrait)
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
            HStack(alignment: .center, spacing: 8) {
                sectionTitle("Link")
                Spacer(minLength: 0)
                // スイッチだけでは何を切り替えるのか分からないので、名前を添える。
                Text("monitor")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Toggle("Monitor", isOn: Binding(
                    get: { controller.monitorOn },
                    set: { controller.setMonitorOn($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.72, anchor: .trailing)
                .frame(height: 18, alignment: .trailing)
            }
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

    private func depthSection(long: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Depth")
            depthHeatmap(long: long)
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
                        Text(String(format: "%.2f–%.1f m", DepthPreview.nearM, DepthPreview.farM))
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
}
