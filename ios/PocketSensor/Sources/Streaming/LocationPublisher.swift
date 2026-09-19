import Foundation
import PocketSensorCore
import PocketSensorServer

/// GNSS の測位を navSatFix と timeReference にする。header は単調時計へ写した値。
final class LocationPublisher {
    private let runtime: StreamingRuntime

    init(runtime: StreamingRuntime) {
        self.runtime = runtime
    }

    func publish(_ sample: LocationSample) {
        guard !runtime.isStopped else { return }
        let wantFix = runtime.server.hasSubscribers("gnss_fix")
        let wantTime = runtime.server.hasSubscribers("gnss_time_reference")
        guard wantFix || wantTime else { return }
        let wallNs = Int64((sample.timestamp.timeIntervalSince1970 * 1_000_000_000.0).rounded())
        let sensorS = runtime.anchor.sensorSeconds(
            wallTimestampNs: wallNs,
            nowWallNs: SessionClocks.wallNs(),
            nowMonoNs: SessionClocks.mediaNs()
        )
        let stampNs = runtime.anchor.wireTime(sensorSeconds: sensorS)
        let names = runtime.names()
        if wantFix {
            runtime.server.publish(
                "gnss_fix",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.navSatFix(
                    stampNs: stampNs,
                    names: names,
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    ellipsoidalAltitude: sample.ellipsoidalAltitude,
                    horizontalAccuracy: sample.horizontalAccuracy,
                    verticalAccuracy: sample.verticalAccuracy
                ))
            )
        }
        if wantTime {
            let wallTimeNs = wallNs < 0 ? UInt64(0) : UInt64(wallNs)
            runtime.server.publish(
                "gnss_time_reference",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.timeReference(
                    stampNs: stampNs,
                    wallTimeNs: wallTimeNs,
                    source: "gnss"
                ))
            )
        }
    }
}
