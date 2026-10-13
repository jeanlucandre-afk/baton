"""Adds a release to site/appcast.xml, the Sparkle feed Baton checks for updates (newest first).
   python3 -I Scripts/appcast.py <version> <build> <zip url> <release notes url> '<sign_update output>'
`sign_update` prints the signature and length as XML attributes, which go on the enclosure as they are."""
import re, sys
from email.utils import formatdate

version, build, url, notes, signed = sys.argv[1:6]
if not re.fullmatch(r'sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"', signed.strip()):
    sys.exit(f"Unexpected sign_update output: {signed!r}")
path = "site/appcast.xml"
feed = open(path).read()
if f"<sparkle:version>{build}</sparkle:version>" in feed:
    sys.exit(f"Build {build} is already in the feed. Bump CFBundleVersion in App/project.yml.")
item = f"""    <item>
      <title>Baton {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{notes}</sparkle:releaseNotesLink>
      <enclosure url="{url}" type="application/octet-stream" {signed.strip()}/>
    </item>
"""
# After the channel's own fields, before the previous newest item.
i = feed.find("    <item>")
i = i if i >= 0 else feed.index("  </channel>")
open(path, "w").write(feed[:i] + item + feed[i:])
print(f"Feed: added Baton {version} (build {build})")
