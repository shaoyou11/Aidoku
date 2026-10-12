"""Exercise the production image request factory with real Nuke decoding on macOS."""
from pathlib import Path
import sys
out = Path(sys.argv[1])
nuke = str(Path(sys.argv[2]).resolve())
(out / 'Sources' / 'Check').mkdir(parents=True)
(out / 'Package.swift').write_text('''// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "NASImages", platforms: [.macOS(.v14)], dependencies: [.package(path: "%s")], targets: [.executableTarget(name: "Check", dependencies: [.product(name: "Nuke", package: "Nuke")])], swiftLanguageModes: [.v5])
''' % nuke)
s = Path('Aidoku/Features/Reader/Page/ReaderPageView.swift').read_text()
a = s.index('    static func imageRequest(url:', s.index('    static func imageRequest(url:') + 1)
b = s.index('\n    func setPageImage', a)
method = s[a:b]
# Bind both real entry points to the same production factory under test.
node = Path('Aidoku/Features/Reader/Readers/Webtoon/ReaderWebtoonPageNode.swift').read_text()
assert 'await ReaderPageView.imageRequest(url: url, context: context, source: source, width: pageWidth)' in node
assert 'let urlRequest = ' not in node[node.index('private func loadImage(url:'):node.index('private func loadImage(base64:')]
(out / 'Sources' / 'Check' / 'Factory.swift').write_text('import AppKit\nimport Nuke\n@MainActor enum ReaderPageView {\n' + method + '\n}\n')
(out / 'Sources' / 'Check' / 'main.swift').write_text(Path('Tests/NASImages/main.swift').read_text())
