import UIKit
import CoreLocation

class BackgroundKeepAliveManager {
    static let shared = BackgroundKeepAliveManager()
    
    private var isRunning = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    private init() {
        setupLifecycleObservers()
    }
    
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.beginBackgroundTask()
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.endBackgroundTask()
            if self.isRunning { LocationAndNavigationManager.shared.startUpdating() }
        }
    }
    
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return }
        isRunning = true
        // Locking the display is allowed; live ride telemetry uses Core Location.
        UIApplication.shared.isIdleTimerDisabled = false
        LocationAndNavigationManager.shared.setTFTRideActive(true)
        if UIApplication.shared.applicationState == .background { beginBackgroundTask() }
    }
    
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning else { return }
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        LocationAndNavigationManager.shared.setTFTRideActive(false)
        endBackgroundTask()
    }
    
    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "KoveMirrorStreamKeepAlive") { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}
