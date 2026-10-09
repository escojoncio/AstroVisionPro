#!/usr/bin/env python3
"""The VPEngine build of the app: project.yml with the game's code run by VPEngine (no FEX, no
JIT) instead. Writes project-vpengine.yml and build/Info-VPEngine.plist next to project.yml:

  - Swift: the VPENGINE condition (HomeView, AppModel... take the VPEngine paths), VPEngine's
    game pack loader and on-headset conversion (VPGamePack.swift, VPConversion.swift) and its
    code signer (vp_codesign.c);
  - links libVPRuntime (the runtime the emulator and the game packs share) and vpconvert
    (vpaot + clang + lld, to convert a game on the headset);
  - bundles VPEngineSDK (what the compiler needs) and VPEngineCertificates (Apple's
    intermediate and root certificates, which a signature carries);
  - Info.plist: the background task that continues a conversion, the URL scheme SideStore calls
    back with the certificate.

    vpengine-project.py VPENGINE_DIR VPCONVERT_DIR
"""
import plistlib
import sys
from pathlib import Path

import yaml

here = Path(__file__).resolve().parent.parent  # visionos/
vpengine = Path(sys.argv[1]).resolve()
vpconvert = Path(sys.argv[2]).resolve()

spec = yaml.safe_load((here / "project.yml").read_text())
target = spec["targets"]["AstroQuest"]
settings = target["settings"]["base"]

target["sources"] = list(target["sources"]) + [
    {"path": str(vpengine / "platform/visionos/Sources/VPGamePack.swift")},
    {"path": str(vpengine / "platform/visionos/Sources/VPConversion.swift")},
    {"path": str(vpengine / "runtime/vp_codesign.c")},
    {"path": "build/VPEngineSDK", "type": "folder", "buildPhase": "resources"},
    {"path": "build/VPEngineCertificates", "type": "folder", "buildPhase": "resources"},
]
settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) VPENGINE"
settings["SWIFT_OBJC_BRIDGING_HEADER"] = "App/Bridge/AstroQuest-VPEngine-Bridging-Header.h"
settings["HEADER_SEARCH_PATHS"] = list(settings["HEADER_SEARCH_PATHS"]) + [
    str(vpengine / "runtime"), str(vpconvert / "include")]
settings["LIBRARY_SEARCH_PATHS"] = list(settings["LIBRARY_SEARCH_PATHS"]) + [str(vpconvert / "lib")]
settings["OTHER_LDFLAGS"] = list(settings["OTHER_LDFLAGS"]) + ["-lVPRuntime", "-lvpconvert_all"]
settings["INFOPLIST_FILE"] = "build/Info-VPEngine.plist"
# The runtime is in the app's Frameworks (copied in when the IPA is made).
settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks"]

(here / "project-vpengine.yml").write_text(yaml.safe_dump(spec, sort_keys=False))

with open(here / "App/Info.plist", "rb") as f:
    info = plistlib.load(f)
info["CFBundleDisplayName"] = "AstroQuest VPEngine"
info["BGTaskSchedulerPermittedIdentifiers"] = ["vpengine.conversion"]
info["UIBackgroundModes"] = ["processing"]
schemes = info.setdefault("LSApplicationQueriesSchemes", [])
for s in ("sidestore", "altstore-classic"):
    if s not in schemes:
        schemes.append(s)
info["CFBundleURLTypes"] = [{"CFBundleURLName": "vpengine.certificate", "CFBundleURLSchemes": ["vpengine"]}]
(here / "build").mkdir(exist_ok=True)
with open(here / "build/Info-VPEngine.plist", "wb") as f:
    plistlib.dump(info, f)
print("project-vpengine.yml and build/Info-VPEngine.plist written")
