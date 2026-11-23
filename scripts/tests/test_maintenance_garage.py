"""Static release checks for the local-first garage module."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GarageMaintenanceReleaseTests(unittest.TestCase):
    def test_three_dot_menu_opens_the_garage(self):
        view = (ROOT / "KoveMirror/WebCockpitView.swift").read_text()
        self.assertIn("case .maintenance: MaintenanceHomeView(bleController: bleController)", view)
        self.assertIn('accessibilityIdentifier("menu.maintenance")', view)
        self.assertIn('present(.maintenance)', view)

    def test_vehicle_title_comes_from_brand_and_model(self):
        model = (ROOT / "KoveMirror/Maintenance/MaintenanceGarage.swift").read_text()
        self.assertIn('var title: String { "\\(brand) \\(model)"', model)
        self.assertIn('var motorcycleID: UUID', model)
        self.assertIn('private var database: URL', model)
        self.assertIn('try data.write(to: database, options: .atomic)', model)

    def test_own_photos_and_dealer_pdf_are_real_features(self):
        views = (ROOT / "KoveMirror/Maintenance/MaintenanceViews.swift").read_text()
        model = (ROOT / "KoveMirror/Maintenance/MaintenanceGarage.swift").read_text()
        self.assertIn('PhotosPicker(selection: $selectedPhoto', views)
        self.assertIn('PhotosPicker(selection: $photoSelections', views)
        self.assertIn('GaragePDF.make(moto:', views)
        self.assertIn('MFMailComposeViewController.canSendMail()', views)
        self.assertIn('composer.setToRecipients([payload.recipient])', model)
        self.assertIn('let image = garage.photo(named: moto.photoName)', views)

    def test_maintains_kove_bluetooth_odometer_without_faking_other_engines(self):
        view = (ROOT / "KoveMirror/Maintenance/MaintenanceViews.swift").read_text()
        self.assertIn('bleController.odoDistanceKm', view)
        self.assertIn('connectionState == .connected', view)
        self.assertIn('garage.latestMileage(for: motorcycle.id)', view)


if __name__ == "__main__":
    unittest.main()
