import Foundation

func row(_ href: String, folder: Bool = true, status: String = "200 OK") -> String {
    "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(folder ? "<d:collection/>" : "")</d:resourcetype></d:prop><d:status>HTTP/1.1 \(status)</d:status></d:propstat></d:response>"
}
let base = URL(string: "https://nas.invalid/dav/")!
let xml = "<d:multistatus xmlns:d=\"DAV:\">" + row("/dav/") + row("/dav/%E6%BC%AB%E7%94%BB/")
    + row("/dav/file.json", folder: false) + row("https://foreign.invalid/dav/secret/")
    + row("/dav/private/", status: "403 Forbidden") + row("/dav/deep/child/")
    + row("/other/") + row("/dav/%E6%BC%AB%E7%94%BB/") + "</d:multistatus>"
let folders = try NASFolderListing.decode(Data(xml.utf8), at: base)
precondition(folders.count == 1 && folders[0].name == "漫画", "must include only direct, authorized, same-origin collections")
let empty = "<d:multistatus xmlns:d=\"DAV:\">" + row("/dav/") + "</d:multistatus>"
let emptyRows = try NASFolderListing.decode(Data(empty.utf8), at: base)
precondition(emptyRows.isEmpty)
let invalid = "<html>Login page</html>"
do { _ = try NASFolderListing.decode(Data(invalid.utf8), at: base); fatalError("HTML accepted") } catch NASSyncError.invalidDocument {}
let denied = "<d:multistatus xmlns:d=\"DAV:\">" + row("/dav/", status: "403 Forbidden") + "</d:multistatus>"
do { _ = try NASFolderListing.decode(Data(denied.utf8), at: base); fatalError("denied folder accepted") } catch NASSyncError.invalidDocument {}
let relative = "<d:multistatus xmlns:d=\"DAV:\">" + row("/dav/") + row("child/") + "</d:multistatus>"
let relativeRows = try NASFolderListing.decode(Data(relative.utf8), at: base)
precondition(relativeRows.count == 1 && relativeRows[0].url.path == "/dav/child")
print("PASS: folder listing, Chinese names, duplicates, scope, permissions, empty folders and invalid XML")
