import CoreLocation
import Foundation

/// Core Location の 1 測位。高度は楕円体高も含め、単位変換はしない。
struct LocationSample {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var ellipsoidalAltitude: Double
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var speed: Double
    var course: Double
    var speedAccuracy: Double
    var courseAccuracy: Double
}

/// `CLLocationManager` を回し、届いた測位を加工せず callback へ渡す。
///
/// 権限のダイアログは `start()` のときだけ出す。起動時には出さない。
final class LocationCapture: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var manager: CLLocationManager?
    private let queue = DispatchQueue(label: "pocketsensor.location")
    private let handlers = HandlerList<LocationSample>()
    private let lock = NSLock()
    private var running = false
    private var status = CLAuthorizationStatus.notDetermined

    /// 最後に知った許可の状態。diagnostics が、測位が届かない理由として流す。
    var authorizationStatus: CLAuthorizationStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    func onLocation(_ handler: @escaping (LocationSample) -> Void) {
        handlers.add(handler)
    }

    /// 許可の状態を読めるようにする。manager を作るだけなので、ダイアログは出ない。
    func prepare() {
        DispatchQueue.main.async { self.ensureManager() }
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        DispatchQueue.main.async {
            let manager = self.ensureManager()
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
        }
    }

    /// CLLocationManager はランループのあるスレッドで作るので、main から呼ぶ。
    @discardableResult
    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyBest
        created.distanceFilter = kCLDistanceFilterNone
        manager = created
        remember(created.authorizationStatus)
        return created
    }

    private func remember(_ value: CLAuthorizationStatus) {
        lock.lock()
        status = value
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        DispatchQueue.main.async {
            self.manager?.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lock.lock()
        let run = running
        lock.unlock()
        guard run, let location = locations.last else { return }
        let sample = LocationSample(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            ellipsoidalAltitude: location.ellipsoidalAltitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            course: location.course,
            speedAccuracy: location.speedAccuracy,
            courseAccuracy: location.courseAccuracy
        )
        queue.async { self.handlers.emit(sample) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        lock.lock()
        status = manager.authorizationStatus
        let run = running
        lock.unlock()
        guard run else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }
}
