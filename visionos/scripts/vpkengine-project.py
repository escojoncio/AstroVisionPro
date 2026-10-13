#!/usr/bin/env python3
"""The VPKEngine build of the app: project.yml with the game's code run by VPKEngine (no FEX, no
JIT) instead. Writes project-vpkengine.yml and build/Info-VPKEngine.plist next to project.yml:

  - Swift: the VPKENGINE condition (HomeView, AppModel... take the VPKEngine paths), VPKEngine's
    game pack loader and on-headset conversion (VPGamePack.swift, VPConversion.swift) and its
    code signer (vp_codesign.c);
  - links libVPRuntime (the runtime the emulator and the game packs share) and vpconvert
    (vpaot + clang + lld, to convert a game on the headset);
  - bundles VPKEngineSDK (what the compiler needs) and VPKEngineCertificates (Apple's
    intermediate and root certificates, which a signature carries);
  - Info.plist: the background task that continues a conversion, the URL scheme SideStore calls
    back with the certificate.

    vpkengine-project.py VPKENGINE_DIR VPCONVERT_DIR
"""
import plistlib
import sys
from pathlib import Path

import yaml

here = Path(__file__).resolve().parent.parent  # visionos/
vpkengine = Path(sys.argv[1]).resolve()
vpconvert = Path(sys.argv[2]).resolve()

spec = yaml.safe_load((here / "project.yml").read_text())
target = spec["targets"]["AstroQuest"]
settings = target["settings"]["base"]

target["sources"] = list(target["sources"]) + [
    {"path": str(vpkengine / "platform/visionos/Sources/VPGamePack.swift")},
    {"path": str(vpkengine / "platform/visionos/Sources/VPConversion.swift")},
    {"path": str(vpkengine / "runtime/vp_codesign.c")},
    # .p12 files Apple's SecPKCS12Import cannot read (OpenSSL 3's AES encryption: iloader's).
    {"path": str(vpkengine / "runtime/vp_pkcs12.c")},
    {"path": "build/VPKEngineSDK", "type": "folder", "buildPhase": "resources"},
    {"path": "build/VPKEngineCertificates", "type": "folder", "buildPhase": "resources"},
]
settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) VPKENGINE"
settings["SWIFT_OBJC_BRIDGING_HEADER"] = "App/Bridge/AstroQuest-VPKEngine-Bridging-Header.h"
settings["HEADER_SEARCH_PATHS"] = list(settings["HEADER_SEARCH_PATHS"]) + [
    str(vpkengine / "runtime"), str(vpconvert / "include")]
settings["LIBRARY_SEARCH_PATHS"] = list(settings["LIBRARY_SEARCH_PATHS"]) + [str(vpconvert / "lib")]
# vpconvert first: it carries the Zydis vpaot is built against, and the emulator's archive another
# Zydis commit (build-core.sh leaves it out in this build). Both define the same symbols; a static
# library search takes the first library that has one, and another version may lay out its
# structs and number its registers differently.
# The emulator only uses Zydis on x86-64 hosts (cpu_patches, x86 SRT walkers), never here.
ldflags = list(settings["OTHER_LDFLAGS"])
ldflags.insert(ldflags.index("-lastroquest_core"), "-lvpconvert_all")
settings["OTHER_LDFLAGS"] = ldflags + ["-lVPRuntime"]
settings["INFOPLIST_FILE"] = "build/Info-VPKEngine.plist"
# The runtime is in the app's Frameworks (copied in when the IPA is made).
settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks"]

(here / "project-vpkengine.yml").write_text(yaml.safe_dump(spec, sort_keys=False))

with open(here / "App/Info.plist", "rb") as f:
    info = plistlib.load(f)
info["CFBundleDisplayName"] = "AstroQuest VPEngine"
info["BGTaskSchedulerPermittedIdentifiers"] = ["vpkengine.conversion"]
info["UIBackgroundModes"] = ["processing"]
schemes = info.setdefault("LSApplicationQueriesSchemes", [])
for s in ("sidestore", "altstore-classic"):
    if s not in schemes:
        schemes.append(s)
info["CFBundleURLTypes"] = [{"CFBundleURLName": "vpkengine.certificate", "CFBundleURLSchemes": ["vpkengine"]}]
(here / "build").mkdir(exist_ok=True)
with open(here / "build/Info-VPKEngine.plist", "wb") as f:
    plistlib.dump(info, f)
print("project-vpkengine.yml and build/Info-VPKEngine.plist written")
