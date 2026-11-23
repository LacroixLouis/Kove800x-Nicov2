// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "NicoMirrorConnection",
    platforms: [.macOS(.v12)],
    products: [.library(name: "NicoMirrorConnection", targets: ["NicoMirrorConnection"])],
    targets: [
        .target(name: "NicoMirrorConnection", path: "KoveMirror/SetupViews",
            exclude: ["QRScannerSheet.swift", "QRCodeScannerView.swift"],
            sources: ["KoveScreenPreset.swift", "MotorcycleWiFiCredentials.swift", "NewlinePacketBuffer.swift",
                      "ProjectionPolicy.swift", "MapCameraFocus.swift", "LockedRidePolicy.swift", "AnnexBResynchronizer.swift", "GPXTrack.swift",
                      "TFTConnectionPolicy.swift", "MotorcycleDistances.swift", "WebPanelLayout.swift", "OfflineTileGrid.swift", "GPXRouteGuidance.swift", "GPXAccessTarget.swift", "RoadRouteProgress.swift", "GPXAlertPolicy.swift", "TomTomTrafficModels.swift", "WizeCommunityModels.swift", "WukulucSharedModels.swift"]),
        .testTarget(name: "NicoMirrorConnectionTests", dependencies: ["NicoMirrorConnection"], path: "Tests/Connection")
    ])
