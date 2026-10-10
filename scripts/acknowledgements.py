"""Prints one entry per Homebrew package: version, license and source.

Usage: brew info --json=v2 PACKAGE... | acknowledgements.py PACKAGE=VERSION...
"""
import json
import sys

installed = dict(arg.split("=", 1) for arg in sys.argv[1:])
for formula in json.load(sys.stdin)["formulae"]:
    name = formula["name"]
    stable = formula["urls"]["stable"]
    source = stable["url"]
    if stable.get("revision"):
        source += " (revision %s)" % stable["revision"]
    print(name)
    print("  Version %s, %s" % (installed[name], formula["license"] or "see license file"))
    print("  Source: %s" % source)
    print("  Homepage: %s" % formula["homepage"])
    print()
