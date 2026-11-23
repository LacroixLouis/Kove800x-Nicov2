from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2] / 'KoveMirror' / 'Maintenance'
class InvoiceReleaseTests(unittest.TestCase):
    def test_legacy_archive_and_category_isolation(self):
        model = (ROOT / 'MaintenanceGarage.swift').read_text()
        self.assertIn('var invoices: [GarageInvoice]?', model)
        self.assertIn('saved.invoices ?? []', model)
        self.assertIn('$0.motorcycleID == motorcycleID && $0.category == category', model)
    def test_single_record_share(self):
        model = (ROOT / 'MaintenanceGarage.swift').read_text()
        views = (ROOT / 'MaintenanceViews.swift').read_text()
        self.assertIn('guard entries.count == 1', model)
        self.assertIn('entries: [entry]', views)
        self.assertNotIn('Partager tout le journal', views)
