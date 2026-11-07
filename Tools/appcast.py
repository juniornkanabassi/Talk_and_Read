#!/usr/bin/python3 -I
"""Appcast edits for release.sh. The feed is read as XML and edited as text, so every other byte stays as it was.

  add      <source> <out> <version> <build> <url> <length> <sig> <notes> <resume 0|1> <min_macos> [beta]
  promote  <source> <out> <version>    drop the beta channel tag from that item, so every user is offered it
  withdraw <source> <out> <version>    drop that item, so the feed stops offering it (installed copies stay)
  enclosure <source> <version>         print url, length, signature, build, minimum macOS and channel (beta or full), one per line

A missing <source> is a new feed for `add`. Anything it cannot read for certain stops it (exit 1, reason on stderr).
"""
import email.utils, html, os, re, sys, xml.etree.ElementTree as ET

SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
BLOCK = r"[ \t]*<item\b.*?</item>[ \t]*\n?"
NEW_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Talk &amp; Read</title>
    <link>https://juniornkanabassi.com/apps/talkandread/</link>
    <description>Updates for Talk &amp; Read</description>
    <language>en</language>
  </channel>
</rss>
"""


def one(item, name):
    """A value Sparkle reads from any of the item's elements (it picks one by language) or from the enclosure's
    attribute; values that differ are ambiguous."""
    enclosure = item.find("enclosure")
    if any(len(el) for el in item.findall(SP + name)):   # Sparkle reads all nested text; refuse rather than differ
        sys.exit(f"an appcast item's {name} holds child elements: refusing to guess")
    values = [el.text or "" for el in item.findall(SP + name)] + ([] if enclosure is None else [enclosure.get(SP + name)])
    found = {v.strip() for v in values if v is not None}
    if len(found) > 1:
        sys.exit(f"an appcast item has two {name} values {sorted(found)}: refusing to guess")
    return next(iter(found), None)


def channel(item):
    """None (the default channel) or "beta"; any other channel name is not one this script publishes."""
    found = [(el.text or "").strip() for el in item.findall(SP + "channel")]
    if len(found) > 1 or any(len(el) for el in item.findall(SP + "channel")) or any(c != "beta" for c in found):
        sys.exit(f"an appcast item's channel {found} is not a single 'beta': refusing to guess")
    return found[0] if found else None


def items(text):
    """Every item's (build, version, channel); anything this script cannot read for certain stops it."""
    if any(uri != SP[1:-1] for uri in re.findall(r'xmlns:sparkle\s*=\s*["\']([^"\']*)', text)):
        sys.exit("the appcast binds the sparkle prefix to another namespace, which Sparkle would still read: refusing to guess")
    # New items are written with the sparkle prefix, so the rss element itself must bind it to Sparkle's namespace.
    if not re.search(r'<rss\b[^>]*\bxmlns:sparkle\s*=\s*["\']' + re.escape(SP[1:-1]) + '["\']', text):
        sys.exit("the appcast's rss element does not declare xmlns:sparkle")
    root = ET.fromstring(text.encode("utf-8"))
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1 or len(root.findall(".//item")) != len(channels[0].findall("item")):
        sys.exit("the appcast must be one RSS channel holding every item")
    out = []
    for item in channels[0].findall("item"):
        if len(item.findall("enclosure")) != 1:
            sys.exit(f"an appcast item has {len(item.findall('enclosure'))} enclosures; only one download per item is supported")
        if not (item.find("enclosure").get("url") or "").startswith("https://"):
            sys.exit("an appcast item's enclosure has no https url, which makes Sparkle reject the whole feed")
        b = one(item, "version")
        if b is None or not b.isdigit():
            sys.exit(f"an appcast item's build number is {b!r}, not a whole number")
        out.append((int(b), one(item, "shortVersionString"), channel(item)))
    if len({b for b, _, _ in out}) != len(out):
        sys.exit("the appcast lists one build number twice")
    return out


def withdrawn(feed):
    """Builds `withdraw` took out. A comment is the one thing that survives in the feed (outside every item, so a note in
    an item's text never counts); no later build may reuse one, or copies that installed it would never be offered the fix."""
    return [int(b) for b in re.findall(r"<!--\s*withdrawn build (\d+)\s*-->", re.sub(BLOCK, "", feed, flags=re.S))]


def read(path, missing_ok=False):
    if missing_ok and not os.path.exists(path):
        return NEW_FEED
    return open(path, encoding="utf-8").read()


def locate(feed, version):
    """The item for `version`: all items, their text blocks, and the index of that item."""
    known = items(feed)
    blocks = re.findall(BLOCK, feed, re.S)
    if len(blocks) != len(known):
        sys.exit("the appcast's items cannot be matched to its text one to one")
    hits = [i for i, (_, v, _) in enumerate(known) if v == version]
    if len(hits) != 1:
        sys.exit(f"the appcast has {len(hits)} items for version {version}; expected exactly one")
    return known, blocks, hits[0]


def parse_block(block):
    return ET.fromstring(f'<x xmlns:sparkle="{SP[1:-1]}">{block}</x>'.encode("utf-8"))[0]


def enclosures(feed):
    return [parse_block(b).find("enclosure").attrib for b in re.findall(BLOCK, feed, re.S)]


def add(source, path, version, build, url, length, sig, notes, resume, min_macos, chan=""):
    notes = open(notes, encoding="utf-8").read().strip()
    e = lambda s: html.escape(s, quote=True)
    feed = read(source, missing_ok=True)
    # Installed copies compare build numbers, so every release needs a higher one; only a resumed release may repeat its own.
    if not build.isdigit():
        sys.exit(f"CFBundleVersion '{build}' is not a whole number")
    known = items(feed)
    blocks = re.findall(BLOCK, feed, re.S)
    if len(blocks) != len(known):
        sys.exit("the appcast's items cannot be matched to its text one to one")
    gone = withdrawn(feed)
    top = max([b for b, _, _ in known] + gone, default=0)
    mine = [k for k in known if k[:2] == (top, version)]
    resumed = int(build) == top and resume == "1" and bool(mine)
    if int(build) <= top and not resumed:
        sys.exit(f"build {build} must be greater than every build in the appcast (highest {top}{', withdrawn' if top in gone else ''}); equal only with --resume for the same version")
    if resumed:
        if mine[0][2] != (chan or None):   # never turn a promoted item back into a beta, or a beta into a full release
            sys.exit(f"the appcast's item for {version} is {'a beta' if mine[0][2] else 'a full release'}; --resume must say the same (--promote changes a beta into a full release)")
        feed = feed.replace(blocks[known.index(mine[0])], "", 1)
    tag = f"      <sparkle:channel>{e(chan)}</sparkle:channel>\n" if chan else ""
    item = f"""    <item>
      <title>Version {e(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{e(build)}</sparkle:version>
      <sparkle:shortVersionString>{e(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{e(min_macos)}</sparkle:minimumSystemVersion>
{tag}      <description sparkle:format="markdown"><![CDATA[{notes}]]></description>
      <enclosure url="{e(url)}" length="{e(length)}" type="application/octet-stream" sparkle:edSignature="{e(sig)}"/>
    </item>
"""
    at = feed.find("<item")
    at = at if at >= 0 else feed.index("</channel>")
    line = feed.rfind("\n", 0, at) + 1
    if not feed[line:at].strip():   # only indentation before it: insert at the start of that line
        at = line
    feed = feed[:at] + item + feed[at:]
    if items(feed)[0] != (int(build), version, chan or None):   # the whole feed still reads, with the new item first
        sys.exit("the new item did not read back as the first item")
    open(path, "w", encoding="utf-8").write(feed)
    print(f"{'Replaced' if resumed else 'Added'} the item for {version} (build {build}{', beta' if chan else ''}); prepared at {path}")


def promote(source, path, version):
    feed = read(source)
    known, blocks, i = locate(feed, version)
    build, _, chan = known[i]
    if chan != "beta":
        sys.exit(f"the appcast's item for {version} is not a beta: nothing to promote")
    # Sparkle offers the highest build in the allowed channels, so a full release above this one would hide it from everyone.
    # A withdrawn build counts too: copies that installed it are above this one as well.
    newer = [b for b, _, c in known if c is None and b > build] + [b for b in withdrawn(feed) if b > build]
    if newer:
        sys.exit(f"a full release or withdrawn build {max(newer)} is already above build {build}: installed copies of it would never be offered {version}. Publish a new build instead")
    block = re.sub(r"[ \t]*<sparkle:channel>\s*beta\s*</sparkle:channel>[ \t]*\n?", "", blocks[i], count=1)
    out = feed.replace(blocks[i], block, 1)
    want = [(b, v, None if k == i else c) for k, (b, v, c) in enumerate(known)]
    if block == blocks[i] or items(out) != want or enclosures(out) != enclosures(feed):
        sys.exit("the beta tag could not be removed cleanly (the item must carry <sparkle:channel>beta</sparkle:channel> on its own line)")
    open(path, "w", encoding="utf-8").write(out)
    print(f"Promoted {version} (build {build}): its channel tag is gone, the enclosure is unchanged; prepared at {path}")


def withdraw(source, path, version):
    feed = read(source)
    known, blocks, i = locate(feed, version)
    build = known[i][0]
    out = feed.replace(blocks[i], f"    <!-- withdrawn build {build} -->\n", 1)
    if items(out) != known[:i] + known[i + 1:] or build not in withdrawn(out):
        sys.exit("the item could not be removed cleanly")
    open(path, "w", encoding="utf-8").write(out)
    print(f"Withdrew {version} (build {build}); prepared at {path}. A comment in the feed keeps build {build} and lower from being reused")


def enclosure(source, version):
    feed = read(source)
    known, blocks, i = locate(feed, version)
    e = parse_block(blocks[i])
    one_ = lambda name: one(e, name) or ""
    a = e.find("enclosure").attrib
    print("\n".join([a.get("url", ""), a.get("length", ""), a.get(SP + "edSignature", ""), str(known[i][0]), one_("minimumSystemVersion"), known[i][2] or "full"]))


if __name__ == "__main__":
    command, args = sys.argv[1], sys.argv[2:]
    {"add": add, "promote": promote, "withdraw": withdraw, "enclosure": enclosure}[command](*args)
