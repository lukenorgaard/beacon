#!/usr/bin/env python3
"""Zip companion/ into build/lookout-companion.vsix.

A .vsix is an OPC zip: `extension.vsixmanifest`, `[Content_Types].xml` and the
extension itself under `extension/`. Writing the two XML files here keeps the
build free of vsce/npm — python3 stdlib only. See docs/history/SPEC.md section 16.2.
"""
import argparse
import json
import os
import sys
import zipfile
from xml.sax.saxutils import escape, quoteattr

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
COMPANION_DIR = os.path.join(REPO_ROOT, "companion")
DEFAULT_OUT = os.path.join(REPO_ROOT, "build", "lookout-companion.vsix")

# Shipped inside the vsix, under extension/.
PAYLOAD = ["package.json", "extension.js", "README.md"]

CONTENT_TYPES = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json" />
  <Default Extension="js" ContentType="application/javascript" />
  <Default Extension="md" ContentType="text/markdown" />
  <Default Extension="txt" ContentType="text/plain" />
  <Default Extension="vsixmanifest" ContentType="text/xml" />
</Types>
"""


def read_manifest():
    with open(os.path.join(COMPANION_DIR, "package.json"), encoding="utf-8") as handle:
        pkg = json.load(handle)
    for key in ("name", "publisher", "version", "displayName", "description", "engines"):
        if not pkg.get(key):
            sys.exit(f"companion/package.json is missing {key!r}")
    return pkg


def vsix_manifest(pkg):
    engine = pkg["engines"]["vscode"]
    categories = ",".join(pkg.get("categories") or ["Other"])
    return f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id={quoteattr(pkg["name"])} Version={quoteattr(pkg["version"])} Publisher={quoteattr(pkg["publisher"])} />
    <DisplayName>{escape(pkg["displayName"])}</DisplayName>
    <Description xml:space="preserve">{escape(pkg["description"])}</Description>
    <Tags></Tags>
    <Categories>{escape(categories)}</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value={quoteattr(engine)} />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value="" />
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.License" Path="extension/LICENSE.txt" Addressable="true" />
  </Assets>
</PackageManifest>
"""


def build(out_path):
    pkg = read_manifest()

    missing = [
        name for name in PAYLOAD if not os.path.isfile(os.path.join(COMPANION_DIR, name))
    ]
    if missing:
        sys.exit("companion/ is missing: " + ", ".join(missing))

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    tmp_path = out_path + ".tmp"
    if os.path.exists(tmp_path):
        os.remove(tmp_path)

    with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("extension.vsixmanifest", vsix_manifest(pkg))
        zf.writestr("[Content_Types].xml", CONTENT_TYPES)
        zf.write(os.path.join(REPO_ROOT, "LICENSE"), "extension/LICENSE.txt")
        for name in PAYLOAD:
            zf.write(os.path.join(COMPANION_DIR, name), f"extension/{name}")

    os.replace(tmp_path, out_path)
    return pkg


def verify(out_path):
    """Fail loudly rather than hand a broken zip to an editor."""
    expected = ["extension.vsixmanifest", "[Content_Types].xml", "extension/LICENSE.txt"] + [
        f"extension/{name}" for name in PAYLOAD
    ]
    with zipfile.ZipFile(out_path) as zf:
        bad = zf.testzip()
        if bad is not None:
            sys.exit(f"corrupt entry in {out_path}: {bad}")
        names = zf.namelist()
        for name in expected:
            if name not in names:
                sys.exit(f"{out_path} is missing {name}")
        manifest = zf.read("extension.vsixmanifest").decode("utf-8")
        package = json.loads(zf.read("extension/package.json").decode("utf-8"))
    if f'Version="{package["version"]}"' not in manifest:
        sys.exit("vsixmanifest version does not match extension/package.json")
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=DEFAULT_OUT, help=f"default: {DEFAULT_OUT}")
    args = parser.parse_args()

    out_path = os.path.abspath(args.out)
    pkg = build(out_path)
    names = verify(out_path)

    size = os.path.getsize(out_path)
    print(f"==> {pkg['publisher']}.{pkg['name']} {pkg['version']}")
    print(f"==> {out_path} ({size} bytes)")
    for name in names:
        print(f"    {name}")
    print("==> ok — install with scripts/install-companion.sh [cursor|devin|vscode|all]")


if __name__ == "__main__":
    main()
