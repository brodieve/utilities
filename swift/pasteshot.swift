// pasteshot.swift
//
// Pastes the most recent screenshot into the frontmost application as PNG
// image data, then restores the user's original clipboard.
//
// Build:
//     swiftc -O -whole-module-optimization -o /usr/local/bin/pasteshot pasteshot.swift
//
// Requires macOS 13+ (UnsafeRawPointer.loadUnaligned) and Accessibility
// permission. See PasteshotError.accessibilityPermissionMissing for which
// process that grant actually attaches to — it depends on how this is launched.
//
// Flags:
//     --copy-only    Write the image to the clipboard and exit. No synthetic
//                    keystroke, so no Accessibility permission is needed and
//                    the clipboard is deliberately left holding the image.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Configuration

private enum Config {
    /// How long the image stays on the pasteboard before the original clipboard
    /// is restored. There is no public notification for "an app finished
    /// reading the pasteboard", so this is a heuristic. Electron apps (Slack,
    /// VS Code, Discord) route paste through a JS layer and need more time than
    /// native ones; tune with PASTESHOT_RESTORE_DELAY_MS.
    static var restoreDelay: TimeInterval {
        let ms = ProcessInfo.processInfo.environment["PASTESHOT_RESTORE_DELAY_MS"]
            .flatMap(Int.init) ?? 100
        return TimeInterval(ms) / 1000
    }

    /// Maximum time spent waiting for physically-held modifier keys to be
    /// released before the synthetic Command-V is posted.
    static var modifierTimeout: TimeInterval {
        let ms = ProcessInfo.processInfo.environment["PASTESHOT_MODIFIER_TIMEOUT_MS"]
            .flatMap(Int.init) ?? 1000
        return TimeInterval(ms) / 1000
    }
}

// MARK: - Errors

enum PasteshotError: Error, CustomStringConvertible {
    case directoryUnreadable(String)
    case noScreenshotFound(String)
    case transcodeFailed(String)
    case accessibilityPermissionMissing
    case eventCreationFailed

    var description: String {
        switch self {
        case .directoryUnreadable(let path):
            return "Could not open the screenshot directory: \(path)"

        case .noScreenshotFound(let path):
            return "No screenshots found in \(path)"

        case .transcodeFailed(let path):
            return "Could not convert to PNG: \(path)"

        case .accessibilityPermissionMissing:
            return """
            Accessibility permission is required to synthesize Command-V.

            The grant belongs to whichever process TCC holds responsible. Exec'd
            from a shell or a hotkey launcher that is the launcher — Terminal,
            Shortcuts, Raycast — and this binary never appears in the list.
            Launched through LaunchServices (`open`, a .app bundle, a
            LaunchAgent) it is responsible for itself and needs its own grant.

            To see which applies:
                sudo launchctl procinfo <pid> | grep responsible

            Grant in System Settings > Privacy & Security > Accessibility, then
            restart the process that holds the grant — a running process keeps
            the answer it got at launch. Use --copy-only to skip the keystroke.
            """

        case .eventCreationFailed:
            return "Could not create keyboard events."
        }
    }
}

// MARK: - Screenshot directory

enum ScreenshotLocation {
    static func directory() -> String {
        let desktop = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Desktop")

        guard let raw = UserDefaults.standard
            .persistentDomain(forName: "com.apple.screencapture")?["location"]
            as? String
        else {
            return desktop
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return desktop }

        let expanded = (trimmed as NSString).expandingTildeInPath

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: expanded,
            isDirectory: &isDirectory
        )

        return (exists && isDirectory.boolValue) ? expanded : desktop
    }
}

// MARK: - Newest-file scan

/// Finds the most recently modified image in a directory using
/// getattrlistbulk(2), which returns names and modification times for roughly a
/// thousand entries per syscall. No NSURL, NSString or NSMetadataQuery in the
/// hot path, and no dependency on Spotlight having indexed the file yet — the
/// screenshot is visible the instant it lands on disk.
enum NewestImage {

    // attrlist bitmap values, written out because the imported Darwin constants
    // have inconsistent signedness.
    private static let attrReturned: UInt32 = 0x8000_0000
    private static let attrName: UInt32 = 0x0000_0001
    private static let attrModTime: UInt32 = 0x0000_0400

    /// The formats macOS actually captures in: PNG for SDR, HEIF for HDR, plus
    /// JPEG since ScreenCaptureKit lists it alongside the other two.
    ///
    /// Matching only ".png" would mean an HDR capture silently pastes a
    /// weeks-old PNG instead of failing. Note this does not cover the legacy
    /// `defaults write com.apple.screencapture type tiff|gif|bmp` values, which
    /// `screencapture -t` still honours.
    private static let allowedExtensions: Set<UInt32> = Set(
        ["png", "heic", "heif", "jpg", "jpeg"]
            .compactMap(extensionCode(of:))
    )

    /// Packs up to four lowercased ASCII bytes into a UInt32 for comparison
    /// without allocating a String per directory entry.
    private static func extensionCode(of text: String) -> UInt32? {
        let bytes = Array(text.utf8)
        guard (3...4).contains(bytes.count) else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1 | 0x20) }
    }

    private static func extensionCode(
        name: UnsafePointer<UInt8>,
        length: Int
    ) -> UInt32? {
        // Extensions are short; only look at the tail of the name.
        var dot = -1
        var index = length - 1
        let floor = max(0, length - 6)

        while index >= floor {
            if name[index] == 0x2E { dot = index; break }  // '.'
            index -= 1
        }

        guard dot >= 0 else { return nil }

        let extensionLength = length - dot - 1
        guard (3...4).contains(extensionLength) else { return nil }

        var code: UInt32 = 0
        for offset in 0..<extensionLength {
            code = (code << 8) | UInt32(name[dot + 1 + offset] | 0x20)
        }

        return code
    }

    static func path(in directory: String) throws -> String {
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw PasteshotError.directoryUnreadable(directory)
        }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(attrReturned | attrName | attrModTime)

        let capacity = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: 8
        )
        defer { buffer.deallocate() }

        var bestName: String?
        var bestSeconds = Int.min
        var bestNanoseconds = 0

        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, capacity, 0)
            if count <= 0 { break }  // 0 = end of directory, -1 = error

            var entry = UnsafeRawPointer(buffer)

            for _ in 0..<Int(count) {
                let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
                var cursor = entry + MemoryLayout<UInt32>.size

                // ATTR_CMN_RETURNED_ATTRS tells us which of the requested
                // attributes are actually present, and therefore where each
                // subsequent field begins.
                let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                cursor += MemoryLayout<attribute_set_t>.size

                var nameReference: UnsafeRawPointer?
                if returned.commonattr & attrName != 0 {
                    nameReference = cursor
                    cursor += MemoryLayout<attrreference_t>.size
                }

                var seconds = Int.min
                var nanoseconds = 0
                if returned.commonattr & attrModTime != 0 {
                    seconds = cursor.loadUnaligned(as: Int.self)
                    nanoseconds = (cursor + MemoryLayout<Int>.size)
                        .loadUnaligned(as: Int.self)
                    cursor += MemoryLayout<timespec>.size
                }

                defer { entry += entryLength }

                guard let nameReference,
                      seconds > bestSeconds
                        || (seconds == bestSeconds && nanoseconds > bestNanoseconds)
                else { continue }

                let nameOffset = Int(nameReference.loadUnaligned(as: Int32.self))
                let nameLength = Int(
                    (nameReference + MemoryLayout<Int32>.size)
                        .loadUnaligned(as: UInt32.self)
                ) - 1  // trailing NUL

                guard nameLength > 0 else { continue }

                let name = (nameReference + nameOffset)
                    .assumingMemoryBound(to: UInt8.self)

                guard let code = extensionCode(name: name, length: nameLength),
                      allowedExtensions.contains(code)
                else { continue }

                bestSeconds = seconds
                bestNanoseconds = nanoseconds
                bestName = String(
                    decoding: UnsafeBufferPointer(start: name, count: nameLength),
                    as: UTF8.self
                )
            }
        }

        guard let bestName else {
            throw PasteshotError.noScreenshotFound(directory)
        }

        return (directory as NSString).appendingPathComponent(bestName)
    }
}

// MARK: - PNG data

enum PNGData {
    /// PNG files — the macOS default — are mapped and handed to the pasteboard
    /// byte for byte. Nothing is decoded, nothing is re-encoded, and the pHYs
    /// chunk survives, which is what tells an app that a 2x retina capture
    /// should display at half its pixel dimensions.
    static func load(path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        if path.lowercased().hasSuffix(".png"),
           let raw = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return raw
        }

        // Non-PNG capture format. Transcode through ImageIO rather than
        // NSImage, which would materialise an uncompressed TIFF on the way.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw PasteshotError.transcodeFailed(path)
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PasteshotError.transcodeFailed(path)
        }

        // Carry DPI across so retina captures keep their intended display size.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        var encodeOptions: [CFString: Any] = [:]
        if let dpiWidth = properties?[kCGImagePropertyDPIWidth] {
            encodeOptions[kCGImagePropertyDPIWidth] = dpiWidth
        }
        if let dpiHeight = properties?[kCGImagePropertyDPIHeight] {
            encodeOptions[kCGImagePropertyDPIHeight] = dpiHeight
        }

        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw PasteshotError.transcodeFailed(path)
        }

        return encoded as Data
    }
}

// MARK: - Pasteboard

enum Clipboard {
    /// Writes PNG and nothing else.
    ///
    /// No public.tiff: every app worth targeting reads public.png, and writing
    /// TIFF as well would mean decoding the capture and re-encoding tens of
    /// megabytes to satisfy a type nobody asks for.
    ///
    /// No public.file-url: a file URL is what Finder's Command-C produces, and
    /// Slack renders that as a named file attachment. Bare image data is what
    /// "Copy Image" produces, and Slack renders it inline.
    ///
    /// Returns the change count after the write, so the caller can detect
    /// whether anything else has taken ownership since.
    @discardableResult
    static func write(png: Data, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pasteboard.writeObjects([item])

        return pasteboard.changeCount
    }
}

struct PasteboardSnapshot {
    private struct Item {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private let items: [Item]

    /// Note that reading every representation forces promised data to resolve.
    /// Content copied from an application that has since quit cannot survive
    /// this round trip — nothing can make it reappear later.
    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { source in
            Item(representations: source.types.compactMap { type in
                source.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        pasteboard.writeObjects(items.map { saved in
            let item = NSPasteboardItem()
            for representation in saved.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        })
    }
}

// MARK: - Keyboard injection

enum Keyboard {
    private static let virtualKeyV: CGKeyCode = 9  // ANSI V

    /// A hotkey's own modifiers are still physically held when this runs, and
    /// they combine with the synthetic event: Shift would turn the paste into
    /// paste-and-match-style, Option and Control into something else again.
    /// Command is left alone, since that is the modifier being sent anyway.
    private static func waitForModifiers() {
        let blocking: CGEventFlags = [.maskShift, .maskControl, .maskAlternate]
        let deadline = Date(timeIntervalSinceNow: Config.modifierTimeout)

        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(blocking).isEmpty { return }
            usleep(4_000)
        }
    }

    static func sendCommandV() throws {
        waitForModifiers()

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: virtualKeyV,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: virtualKeyV,
                  keyDown: false
              )
        else {
            throw PasteshotError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

// MARK: - Main

func run() throws {
    let copyOnly = CommandLine.arguments.contains("--copy-only")

    // Fail before the clipboard is touched rather than pasting into the void.
    //
    // AXIsProcessTrusted() asks about the calling process, as documented, but
    // TCC resolves that through the responsible-process chain — so the answer
    // reflects the grant held by whatever is responsible for this one. Either
    // way the check is accurate; only the remedy depends on launch method.
    if !copyOnly && !AXIsProcessTrusted() {
        throw PasteshotError.accessibilityPermissionMissing
    }

    // All the slow work happens before the clipboard is disturbed, so the
    // window during which it holds the image is as short as possible.
    let directory = ScreenshotLocation.directory()
    let screenshot = try NewestImage.path(in: directory)
    let png = try PNGData.load(path: screenshot)

    let pasteboard = NSPasteboard.general

    guard !copyOnly else {
        Clipboard.write(png: png, to: pasteboard)
        return
    }

    let original = PasteboardSnapshot(pasteboard: pasteboard)
    let ownedChangeCount = Clipboard.write(png: png, to: pasteboard)

    do {
        try Keyboard.sendCommandV()
    } catch {
        if pasteboard.changeCount == ownedChangeCount {
            original.restore(to: pasteboard)
        }
        throw error
    }

    Thread.sleep(forTimeInterval: Config.restoreDelay)

    // If anything else claimed the pasteboard while the image sat on it, that
    // content is newer than the snapshot and must not be overwritten.
    if pasteboard.changeCount == ownedChangeCount {
        original.restore(to: pasteboard)
    }
}

do {
    try run()
} catch {
    fputs("pasteshot: \(error)\n", stderr)
    exit(1)
}
