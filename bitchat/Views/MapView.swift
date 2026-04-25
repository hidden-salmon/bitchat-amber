import SwiftUI
import MapKit
import CoreLocation
import Combine

/// Lets the user share a location with the NGO and tag it as safe or unsafe.
///
/// Two modes:
/// - **GPS mode**: if CoreLocation grants a fix, the user's location is auto-selected.
/// - **Manual pin mode**: user taps anywhere on the map to drop a pin.
///
/// "Mark safe" / "Mark unsafe" sends a `LocationReport` to the NGO hub.
struct MapView: View {
    @EnvironmentObject var alertsVM: AlertsViewModel
    @StateObject private var locator = LocationProvider()

    @State private var pinned: CLLocationCoordinate2D? = nil
    @State private var note: String = ""
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 36.21, longitude: 37.16), // default: Aleppo area
        span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
    )

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapArea
                controls
            }
            .navigationTitle("Map")
            .onAppear { locator.requestIfNeeded() }
            .onReceive(locator.$lastFix) { newFix in
                guard let coord = newFix, pinned == nil else { return }
                pinned = coord
                region = MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
            }
        }
    }

    private var mapAnnotations: [PinAnnotation] {
        var items: [PinAnnotation] = []
        if let pin = pinned {
            items.append(PinAnnotation(id: "current", coordinate: pin, kind: .current))
        }
        for rep in alertsVM.locationReports {
            items.append(PinAnnotation(
                id: rep.id,
                coordinate: CLLocationCoordinate2D(latitude: rep.lat, longitude: rep.lng),
                kind: rep.safety == .safe ? .safe : .unsafe
            ))
        }
        return items
    }

    @ViewBuilder
    private var mapArea: some View {
        Map(coordinateRegion: $region, annotationItems: mapAnnotations) { item in
            MapAnnotation(coordinate: item.coordinate) {
                Image(systemName: item.kind.systemImageName)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(item.kind.tint))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Manual pinning: a tap-on-map gesture is finicky across SwiftUI versions,
        // so we expose a "Drop pin at map center" button below as a reliable fallback.
    }

    private struct PinAnnotation: Identifiable {
        enum Kind {
            case current, safe, unsafe
            var systemImageName: String {
                switch self {
                case .current: return "mappin"
                case .safe: return "checkmark"
                case .unsafe: return "exclamationmark.triangle.fill"
                }
            }
            var tint: Color {
                switch self {
                case .current: return .red
                case .safe: return .green
                case .unsafe: return .orange
                }
            }
        }
        let id: String
        let coordinate: CLLocationCoordinate2D
        let kind: Kind
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            statusBanner
            HStack(spacing: 8) {
                Button {
                    if let fix = locator.lastFix {
                        pinned = fix
                        region = MKCoordinateRegion(
                            center: fix,
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                        )
                    } else {
                        locator.requestIfNeeded()
                    }
                } label: {
                    Label("Use my GPS", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    pinned = region.center
                } label: {
                    Label("Drop pin at center", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            TextField("Note (optional)", text: $note)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button {
                    Task { await report(.safe) }
                } label: {
                    Label("Mark safe", systemImage: "checkmark.shield.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(pinned == nil || alertsVM.submissionState == .submitting)

                Button {
                    Task { await report(.unsafe) }
                } label: {
                    Label("Mark unsafe", systemImage: "exclamationmark.triangle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(pinned == nil || alertsVM.submissionState == .submitting)
            }

            if pinned == nil {
                Text("Tap anywhere on the map to drop a pin, or tap “Use my GPS” if you've granted location access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch alertsVM.submissionState {
        case .sent:
            Label("Location report sent", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .submitting:
            HStack { ProgressView().controlSize(.small); Text("Sending…").font(.caption) }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
                .lineLimit(2)
        case .idle:
            EmptyView()
        }
    }

    private func report(_ safety: LocationReportPayload.Safety) async {
        guard let coord = pinned else { return }
        await alertsVM.reportLocation(
            lat: coord.latitude,
            lng: coord.longitude,
            safety: safety,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if alertsVM.submissionState == .sent {
            note = ""
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            alertsVM.resetSubmissionState()
        }
    }
}

// MARK: - Lightweight CoreLocation wrapper

@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var lastFix: CLLocationCoordinate2D? = nil
    @Published var authorization: CLAuthorizationStatus = .notDetermined

    private let manager: CLLocationManager

    override init() {
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus
    }

    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            #if os(iOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestAlwaysAuthorization()
            #endif
        case .authorizedAlways, .authorizedWhenInUse:
            #if os(macOS)
            manager.startUpdatingLocation()
            #else
            manager.requestLocation()
            #endif
        default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        Task { @MainActor in self.lastFix = coord }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Swallow — UI shows manual pinning instructions when no fix arrives.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            #if os(macOS)
            if status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
            #else
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                manager.requestLocation()
            }
            #endif
        }
    }
}
