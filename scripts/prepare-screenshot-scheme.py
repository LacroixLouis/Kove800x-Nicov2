#!/usr/bin/env python3
"""Add a separate screenshot scheme without touching signing or the normal scheme."""
from pathlib import Path
import xml.etree.ElementTree as ET
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import xcode_project

root = Path(__file__).resolve().parent.parent
project = xcode_project.loads((root / "NicoMirror.xcodeproj/project.pbxproj").read_text())
targets = {obj.get("name"): (key, obj) for key, obj in project["objects"].items() if obj.get("isa") == "PBXNativeTarget"}
test_id, target = targets["KoveMirrorUITests"]
scheme_path = root / "NicoMirror.xcodeproj/xcshareddata/xcschemes"
tree = ET.parse(scheme_path / "NicoMirror.xcscheme")
testables = tree.find("./TestAction/Testables")
for child in list(testables): testables.remove(child)
ref = ET.SubElement(ET.SubElement(testables, "TestableReference", {"skipped": "NO"}), "BuildableReference")
ref.attrib.update({"BuildableIdentifier": "primary", "BlueprintIdentifier": test_id,
                  "BuildableName": "KoveMirrorUITests.xctest", "BlueprintName": "KoveMirrorUITests",
                  "ReferencedContainer": "container:NicoMirror.xcodeproj"})
tree.write(scheme_path / "DoubleInterfaceCaptures.xcscheme", encoding="UTF-8", xml_declaration=True)
print("Schéma de captures iOS préparé.")
