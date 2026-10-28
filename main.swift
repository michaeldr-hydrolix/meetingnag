// MeetingNag — full-screen meeting alerts for macOS that require confirmation.
// Reads events from the macOS Calendar database (add your Google account in
// System Settings > Internet Accounts). Optional phone escalation via Pushover
// and/or Twilio if you don't acknowledge in time.

import AppKit
import AVFoundation
import EventKit
import IOKit.pwr_mgt

// MARK: - Helpers

func timeString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f.string(from: d)
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

func repeatingTimer(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
    let t = Timer(timeInterval: interval, repeats: true) { _ in block() }
    RunLoop.main.add(t, forMode: .common)
    return t
}

func onceTimer(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
    let t = Timer(timeInterval: interval, repeats: false) { _ in block() }
    RunLoop.main.add(t, forMode: .common)
    return t
}

// MARK: - System volume

enum Volume {
    @discardableResult
    static func run(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    static func get() -> (level: Int, muted: Bool)? {
        guard let v = run("output volume of (get volume settings)"),
              let m = run("output muted of (get volume settings)") else { return nil }
        return (Int(v.int32Value), m.booleanValue)
    }

    static func max() { run("set volume without output muted\nset volume output volume 100") }

    static func restore(_ s: (level: Int, muted: Bool)) {
        run("set volume output volume \(s.level)")
        if s.muted { run("set volume with output muted") }
    }
}

// MARK: - Volume key blocker (needs Accessibility permission)

enum VolumeKeyBlocker {
    static var blocking = false
    static var tap: CFMachPort?
    static var isInstalled: Bool { tap != nil }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func install() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED: media / volume keys
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = VolumeKeyBlocker.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard VolumeKeyBlocker.blocking, type.rawValue == 14,
                  let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8
            else { return Unmanaged.passUnretained(event) }
            let key = (ns.data1 & 0xFFFF0000) >> 16
            if key == 1 || key == 7 { return nil } // NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: callback, userInfo: nil) else { return }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }
}

// MARK: - Power (lid-closed mode)

enum Power {
    /// Created by install.sh only if you enabled lid-closed mode (admin-approved pmset access).
    static var enabled: Bool { FileManager.default.fileExists(atPath: Paths.dir.appendingPathComponent(".lidmode").path) }
    private static var lidSleepDisabled = false
    private static var assertion: IOPMAssertionID = 0
    private static var scheduledWakes = Set<Date>()

    @discardableResult
    static func pmset(_ args: [String]) -> Bool {
        guard enabled else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    /// While on: closing the lid does NOT sleep the Mac, and idle sleep is blocked.
    static func keepAwake(_ on: Bool) {
        guard on != lidSleepDisabled else { return }
        lidSleepDisabled = on
        pmset(["-a", "disablesleep", on ? "1" : "0"])
        if on {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "MeetingNag: meeting starting soon" as CFString, &assertion)
        } else if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    /// Called at launch/quit so a crash can never leave lid sleep disabled.
    static func reset() {
        lidSleepDisabled = true
        keepAwake(false)
    }

    /// Wakes the Mac before a meeting in case it's already asleep with the lid closed.
    static func scheduleWake(at date: Date) {
        guard date > Date().addingTimeInterval(60), !scheduledWakes.contains(date) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yy HH:mm:ss"
        if pmset(["schedule", "wake", f.string(from: date)]) { scheduledWakes.insert(date) }
    }
}

// MARK: - Paths

enum Paths {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingNag", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var config: URL { dir.appendingPathComponent("config.json") }
    static var log: URL { dir.appendingPathComponent("acknowledgements.csv") }
}

// MARK: - Config

struct Config: Codable {
    var configVersion: Int = 2
    var leadMinutes: Double = 1
    var lateAlertMinutes: Double = 10            // still alert for meetings that appear after they've started
    var onlyMeetingsWithAttendees: Bool = true
    var skipDeclined: Bool = true
    var calendars: [String] = []                 // calendar names to watch; empty = all
    var ignoreTitlesContaining: [String] = ["Focus", "OOO", "Out of office"]
    var alertSound: String = "Submarine"         // any name from /System/Library/Sounds
    var repeatSoundEverySeconds: Double = 4
    var speakCountdown: Bool = true              // says "Meeting in N minutes" — never the title
    var maxVolumeDuringAlert: Bool = true        // unmute + 100% volume, restored after you click
    var blockVolumeKeys: Bool = true             // swallow volume-down/mute keys during an alert (needs Accessibility)
    var stayAwakeWithLidClosed: Bool = true      // only works if lid-closed mode was enabled at install
    var wakeMinutesBefore: Double = 8            // stay awake this many minutes before the alert fires
    var escalateAfterSeconds: Double = 60        // 0 = never escalate
    var pushoverUserKey: String = ""
    var pushoverAppToken: String = ""
    var twilioAccountSid: String = ""
    var twilioAuthToken: String = ""
    var twilioFromNumber: String = ""            // e.g. +15551234567
    var twilioToNumber: String = ""              // your mobile, e.g. +15557654321

    /// Loads config.json, filling any missing keys with defaults. Writes a default file on first run.
    static func load() -> Config {
        let defaults = Config()
        let url = Paths.config
        guard let data = try? Data(contentsOf: url) else {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(defaults).write(to: url)
            return defaults
        }
        guard let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any]
        else { return defaults }
        merged.merge(user) { _, new in new }
        // One-time upgrade from earlier versions: move old defaults to new ones, keep anything customised.
        if (user["configVersion"] as? Int ?? 1) < 2 {
            if merged["alertSound"] as? String == "Sosumi" { merged["alertSound"] = "Submarine" }
            if merged["repeatSoundEverySeconds"] as? Double == 8 { merged["repeatSoundEverySeconds"] = 4 }
            if merged["leadMinutes"] as? Double == 3 { merged["leadMinutes"] = 1 }
            merged["configVersion"] = 2
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            if let out = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: url)
            }
        }
        if let md = try? JSONSerialization.data(withJSONObject: merged),
           let c = try? JSONDecoder().decode(Config.self, from: md) {
            return c
        }
        return defaults
    }
}

// MARK: - Acknowledgement log

enum AckLog {
    static func write(meeting m: Meeting, action: String, shownAt: Date) {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let now = Date()
        let secs = String(format: "%.0f", now.timeIntervalSince(shownAt))
        let title = m.title.replacingOccurrences(of: "\"", with: "\"\"")
        let line = "\(f.string(from: now)),\"\(title)\",\(f.string(from: m.start)),\(action),\(secs)\n"
        let url = Paths.log
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "logged_at,meeting,meeting_start,action,seconds_after_alert\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        }
    }
}

// MARK: - Calendar

struct Meeting {
    let key: String
    let eventID: String       // EventKit identifier ("" for the test alert)
    let occurrence: Date      // original occurrence date, identifies one instance of a recurring event
    let title: String
    let start: Date
    let end: Date
    let calendarName: String
    let joinURL: URL?
}

/// Finds the video-call link. Checks the event's URL field first, then location, then notes,
/// and within each field takes the first link that appears.
func findJoinURL(_ e: EKEvent) -> URL? {
    var fields: [String] = []
    if let u = e.url { fields.append(u.absoluteString) }
    if let l = e.location { fields.append(l) }
    if let n = e.notes { fields.append(n) }
    let patterns = [
        #"https://meet\.google\.com/[a-z0-9-]+"#,
        #"https://[\w.-]*zoom\.us/(j|my|w|s)/[^\s<>"']+"#,
        #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"']+"#,
        #"https://teams\.live\.com/meet/[^\s<>"']+"#,
        #"https://[\w.-]*webex\.com/[^\s<>"']+"#,
        #"https://[\w.-]*(whereby\.com|meet\.jit\.si|chime\.aws|gotomeeting\.com|bluejeans\.com|around\.co)/[^\s<>"']+"#,
    ]
    for text in fields {
        let hits = patterns.compactMap { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) }
        if let first = hits.min(by: { $0.lowerBound < $1.lowerBound }) {
            return URL(string: String(text[first]))
        }
    }
    return nil
}

final class CalendarWatcher {
    let store = EKEventStore()
    var hasAccess = false

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in
                DispatchQueue.main.async { self.hasAccess = ok; done(ok) }
            }
        } else {
            store.requestAccess(to: .event) { ok, _ in
                DispatchQueue.main.async { self.hasAccess = ok; done(ok) }
            }
        }
    }

    func meetings(from: Date, to: Date, config: Config) -> [Meeting] {
        guard hasAccess else { return [] }
        var cals = store.calendars(for: .event)
        if !config.calendars.isEmpty {
            let wanted = Set(config.calendars.map { $0.lowercased() })
            cals = cals.filter { wanted.contains($0.title.lowercased()) }
        }
        if cals.isEmpty { return [] }
        let ignore = config.ignoreTitlesContaining.map { $0.lowercased() }.filter { !$0.isEmpty }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: cals)

        let result: [Meeting] = store.events(matching: pred).compactMap { e in
            if e.isAllDay || e.status == .canceled { return nil }
            let title = e.title ?? "(No title)"
            let lower = title.lowercased()
            if ignore.contains(where: { lower.contains($0) }) { return nil }
            let attendees = e.attendees ?? []
            if config.onlyMeetingsWithAttendees && attendees.isEmpty { return nil }
            if config.skipDeclined,
               let me = attendees.first(where: { $0.isCurrentUser }),
               me.participantStatus == .declined { return nil }
            return makeMeeting(e)
        }
        return result.sorted { $0.start < $1.start }
    }

    func makeMeeting(_ e: EKEvent) -> Meeting {
        let title = e.title ?? "(No title)"
        let id: String = e.eventIdentifier ?? ""
        return Meeting(
            key: "\(id.isEmpty ? title : id)|\(e.startDate.timeIntervalSince1970)",
            eventID: id,
            occurrence: e.occurrenceDate ?? e.startDate,
            title: title,
            start: e.startDate,
            end: e.endDate,
            calendarName: e.calendar?.title ?? "",
            joinURL: findJoinURL(e)
        )
    }

    /// Re-reads one meeting from the calendar right now, so the alert shows the current title,
    /// time and link. Returns nil if the meeting was deleted, cancelled or declined.
    func latest(_ m: Meeting) -> Meeting? {
        guard hasAccess, !m.eventID.isEmpty else { return m }
        let pred = store.predicateForEvents(withStart: m.occurrence.addingTimeInterval(-24 * 3600),
                                            end: m.occurrence.addingTimeInterval(24 * 3600), calendars: nil)
        let matches = store.events(matching: pred).filter { $0.eventIdentifier == m.eventID }
        let e = matches.first(where: { $0.occurrenceDate == m.occurrence })
            ?? matches.min(by: { abs($0.startDate.timeIntervalSince(m.start)) < abs($1.startDate.timeIntervalSince(m.start)) })
        guard let ev = e, ev.status != .canceled else { return nil }
        if let me = ev.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return nil }
        return makeMeeting(ev)
    }
}

// MARK: - Phone escalation

enum Escalator {
    static func pushoverOn(_ c: Config) -> Bool { !c.pushoverUserKey.isEmpty && !c.pushoverAppToken.isEmpty }
    static func twilioOn(_ c: Config) -> Bool {
        !c.twilioAccountSid.isEmpty && !c.twilioAuthToken.isEmpty && !c.twilioFromNumber.isEmpty && !c.twilioToNumber.isEmpty
    }
    static func isConfigured(_ c: Config) -> Bool { pushoverOn(c) || twilioOn(c) }

    static func form(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func post(_ url: String, _ params: [String: String], auth: String? = nil,
                     completion: ((Data?) -> Void)? = nil) {
        guard let u = URL(string: url) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let auth = auth { req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization") }
        req.httpBody = form(params)
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { NSLog("MeetingNag escalation error: \(error)") }
            DispatchQueue.main.async { completion?(data) }
        }.resume()
    }

    /// Pushover emergency priority: repeats on the phone every 30s until acknowledged (max 10 min).
    static func pushover(_ c: Config, meeting m: Meeting, receipt: @escaping (String?) -> Void) {
        var p = [
            "token": c.pushoverAppToken,
            "user": c.pushoverUserKey,
            "title": "Meeting at \(timeString(m.start))",
            "message": "You have a meeting at \(timeString(m.start)) and haven't confirmed on your Mac.",
            "priority": "2",
            "retry": "30",
            "expire": "600",
            "sound": "persistent",
        ]
        if let u = m.joinURL { p["url"] = u.absoluteString; p["url_title"] = "Join meeting" }
        post("https://api.pushover.net/1/messages.json", p) { data in
            guard let d = data,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { receipt(nil); return }
            receipt(j["receipt"] as? String)
        }
    }

    static func cancelPushover(_ c: Config, receipt: String) {
        post("https://api.pushover.net/1/receipts/\(receipt)/cancel.json", ["token": c.pushoverAppToken])
    }

    /// Twilio voice call (generic wording — the meeting title is never spoken).
    static func twilioCall(_ c: Config, meeting m: Meeting) {
        let say = xmlEscape("Meeting reminder. You have a meeting at \(timeString(m.start)).")
        let twiml = "<Response><Say>\(say)</Say><Pause length=\"1\"/><Say>\(say)</Say></Response>"
        let auth = Data("\(c.twilioAccountSid):\(c.twilioAuthToken)".utf8).base64EncodedString()
        post("https://api.twilio.com/2010-04-01/Accounts/\(c.twilioAccountSid)/Calls.json",
             ["To": c.twilioToNumber, "From": c.twilioFromNumber, "Twiml": twiml], auth: auth)
    }
}

// MARK: - Full-screen alert

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AlertController: NSObject {
    var config: Config
    var onFinished: (() -> Void)?
    var onSnooze: ((Meeting) -> Void)?

    private(set) var current: Meeting?
    private var windows: [NSWindow] = []
    private var countdownLabels: [NSTextField] = []
    private var tickTimer: Timer?
    private var soundTimer: Timer?
    private var escalateTimer: Timer?
    private var shownAt = Date()
    private var escalated = false
    private var pushoverReceipt: String?
    private let speech = AVSpeechSynthesizer()
    private var savedVolume: (level: Int, muted: Bool)?
    private var volumeGuardTimer: Timer?
    private var ticks = 0
    /// Re-reads a meeting from the calendar; nil means it no longer needs an alert.
    var refresher: ((Meeting) -> Meeting?)?

    init(config: Config) { self.config = config }

    /// Every 5 s while the alert is up: pick up edits to the title, time or link.
    private func refreshCurrent() {
        guard let m = current, let r = refresher else { return }
        guard let fresh = r(m) else { finish("cancelled_in_calendar"); return }
        if fresh.start.timeIntervalSinceNow > max(config.leadMinutes, 1) * 60 + 120 {
            finish("rescheduled")  // moved later; it will alert again at the new time
            return
        }
        let changed = fresh.title != m.title || fresh.joinURL != m.joinURL
            || fresh.start != m.start || fresh.end != m.end || fresh.calendarName != m.calendarName
        current = fresh
        if changed { rebuildWindows() }
    }

    private func rebuildWindows() {
        guard let m = current else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        countdownLabels.removeAll()
        for screen in NSScreen.screens { windows.append(makeWindow(for: screen, meeting: m)) }
        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
        updateCountdown()
    }

    var isShowing: Bool { current != nil }

    func show(_ queued: Meeting) {
        // Always show what's in the calendar now, not what was there when the alert was queued or snoozed.
        var m = queued
        if let r = refresher {
            guard let fresh = r(queued) else { onFinished?(); return }  // deleted, cancelled or declined
            m = fresh
        }
        current = m
        shownAt = Date()
        escalated = false
        pushoverReceipt = nil
        ticks = 0

        for screen in NSScreen.screens { windows.append(makeWindow(for: screen, meeting: m)) }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)

        updateCountdown()
        tickTimer = repeatingTimer(1) { [weak self] in
            guard let self = self else { return }
            self.updateCountdown()
            self.ticks += 1
            if self.ticks % 5 == 0 { self.refreshCurrent() }
        }
        if config.maxVolumeDuringAlert {
            if savedVolume == nil { savedVolume = Volume.get() }
            Volume.max()
            // Re-check every second so the Control Center slider / headphone buttons can't win either.
            volumeGuardTimer = repeatingTimer(1) {
                if let v = Volume.get(), v.level < 100 || v.muted { Volume.max() }
            }
        }
        VolumeKeyBlocker.blocking = config.blockVolumeKeys
        alarmTick()
        soundTimer = repeatingTimer(max(2, config.repeatSoundEverySeconds)) { [weak self] in self?.alarmTick() }
        if config.escalateAfterSeconds > 0 && Escalator.isConfigured(config) {
            escalateTimer = onceTimer(config.escalateAfterSeconds) { [weak self] in self?.escalate() }
        }
        AckLog.write(meeting: m, action: "alert_shown", shownAt: shownAt)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor.white.withAlphaComponent(alpha)
        l.alignment = .center
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 3
        l.preferredMaxLayoutWidth = 1100
        return l
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.font = .systemFont(ofSize: 20, weight: .semibold)
        return b
    }

    private func makeWindow(for screen: NSScreen, meeting m: Meeting) -> NSWindow {
        let w = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = NSColor(calibratedRed: 0.62, green: 0.07, blue: 0.10, alpha: 0.95)
        w.hasShadow = false
        w.isReleasedWhenClosed = false

        let countdown = label("", size: 30, weight: .medium, alpha: 0.9)
        countdownLabels.append(countdown)
        let title = label(m.title, size: 56, weight: .bold)
        let sub = label("\(timeString(m.start)) – \(timeString(m.end))  ·  \(m.calendarName)",
                        size: 20, weight: .regular, alpha: 0.75)

        var buttons: [NSButton] = []
        if m.joinURL != nil { buttons.append(button("Join meeting", #selector(joinClicked))) }
        buttons.append(button("I'm on it", #selector(ackClicked)))
        buttons.append(button("Snooze 1 min", #selector(snoozeClicked)))
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 20

        var hintText = "Click a button to confirm you've seen this. It keeps chiming until you do."
        if config.escalateAfterSeconds > 0 && Escalator.isConfigured(config) {
            hintText += " Your phone will be alerted in \(Int(config.escalateAfterSeconds))s."
        }
        let hint = label(hintText, size: 14, weight: .regular, alpha: 0.65)

        let stack = NSStackView(views: [countdown, title, sub, row, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 22
        stack.setCustomSpacing(44, after: sub)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.85),
        ])
        w.contentView = content

        // Brief lockout so a stray click or keystroke while you're working can't dismiss it.
        buttons.forEach { $0.isEnabled = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { buttons.forEach { $0.isEnabled = true } }
        return w
    }

    private func updateCountdown() {
        guard let m = current else { return }
        let s = Int(m.start.timeIntervalSinceNow.rounded())
        let text = s > 0
            ? String(format: "Starts in %d:%02d", s / 60, s % 60)
            : String(format: "Started %d:%02d ago", (-s) / 60, (-s) % 60)
        countdownLabels.forEach { $0.stringValue = text }
    }

    /// One alarm cycle: (re)force volume, play the sound, then speak the countdown.
    private func alarmTick() {
        (NSSound(named: NSSound.Name(config.alertSound)) ?? NSSound(named: NSSound.Name("Submarine")))?.play()
        if config.speakCountdown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.speakCountdown() }
        }
    }

    /// Generic phrase only — never includes the meeting title.
    private func speakCountdown() {
        guard let m = current, !speech.isSpeaking else { return }
        let s = m.start.timeIntervalSinceNow
        let phrase: String
        if s > 60 {
            let mins = Int((s / 60).rounded(.up))
            phrase = "Meeting in \(mins) minutes"
        } else if s > 0 {
            phrase = "Meeting in less than a minute"
        } else {
            phrase = "Your meeting has started"
        }
        speech.speak(AVSpeechUtterance(string: phrase))
    }

    private func escalate() {
        guard let m = current else { return }
        escalated = true
        AckLog.write(meeting: m, action: "escalated_to_phone", shownAt: shownAt)
        if Escalator.pushoverOn(config) {
            let cfg = config
            Escalator.pushover(cfg, meeting: m) { [weak self] receipt in
                guard let receipt = receipt else { return }
                // If you already confirmed on the Mac before the receipt arrived, stop the phone alert.
                if self?.current?.key == m.key { self?.pushoverReceipt = receipt }
                else { Escalator.cancelPushover(cfg, receipt: receipt) }
            }
        }
        if Escalator.twilioOn(config) { Escalator.twilioCall(config, meeting: m) }
    }

    @objc private func ackClicked() { finish("acknowledged") }

    @objc private func joinClicked() {
        // Re-check the calendar at click time so a just-changed link is the one that opens.
        var url = current?.joinURL
        if let m = current, let fresh = refresher?(m), let u = fresh.joinURL { url = u }
        if let u = url { NSWorkspace.shared.open(u) }
        finish("joined")
    }

    @objc private func snoozeClicked() {
        guard let m = current else { return }
        finish("snoozed")
        onSnooze?(m)
    }

    private func finish(_ action: String) {
        guard let m = current else { return }
        AckLog.write(meeting: m, action: escalated ? "\(action)_after_escalation" : action, shownAt: shownAt)
        if let r = pushoverReceipt { Escalator.cancelPushover(config, receipt: r) }
        [tickTimer, soundTimer, escalateTimer, volumeGuardTimer].forEach { $0?.invalidate() }
        tickTimer = nil; soundTimer = nil; escalateTimer = nil; volumeGuardTimer = nil
        VolumeKeyBlocker.blocking = false
        speech.stopSpeaking(at: .immediate)
        if let v = savedVolume { Volume.restore(v); savedVolume = nil }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        countdownLabels.removeAll()
        pushoverReceipt = nil
        current = nil
        onFinished?()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let watcher = CalendarWatcher()
    var config = Config.load()
    var alerts: AlertController!
    var alerted: [String: Date] = [:]
    var queue: [Meeting] = []
    var pausedUntil: Date?
    var pollTimer: Timer?
    var pollCount = 0
    var pendingSnoozes = 0

    let menu = NSMenu()
    let nextItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    var pauseItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏰"
        buildMenu()

        alerts = AlertController(config: config)
        alerts.onFinished = { [weak self] in self?.showNextQueued() }
        alerts.refresher = { [weak self] m in
            guard let self = self else { return m }
            return self.watcher.latest(m)
        }
        alerts.onSnooze = { [weak self] m in
            self?.pendingSnoozes += 1
            _ = onceTimer(60) { self?.pendingSnoozes -= 1; self?.enqueue(m) }
        }

        Power.reset()
        if config.blockVolumeKeys { VolumeKeyBlocker.requestPermission(); VolumeKeyBlocker.install() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.watcher.store.refreshSourcesIfNecessary()
            self?.poll()
        }

        watcher.requestAccess { [weak self] ok in
            guard let self = self else { return }
            if !ok { self.showNoAccess() }
            self.poll()
            self.pollTimer = repeatingTimer(15) { [weak self] in self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: watcher.store,
                                               queue: .main) { [weak self] _ in self?.poll() }
    }

    func poll() {
        let now = Date()
        pollCount += 1
        // Ask macOS to sync with Google: every poll while a meeting is near, otherwise every 5 min.
        let meetingNear = alerts.isShowing || !queue.isEmpty
            || !watcher.meetings(from: now, to: now.addingTimeInterval(15 * 60), config: config).isEmpty
        if meetingNear || pollCount % 20 == 0 { watcher.store.refreshSourcesIfNecessary() }
        if config.blockVolumeKeys && !VolumeKeyBlocker.isInstalled { VolumeKeyBlocker.install() }

        if let p = pausedUntil, p > now { Power.keepAwake(false); updateIcon(); return }
        pausedUntil = nil
        updateLidMode(now)

        let lead = config.leadMinutes * 60
        // Also catch meetings that reached this Mac late (moved or created at the last minute, slow
        // Google sync, Mac just woke up): still alert if they started within lateAlertMinutes.
        let late = max(1, config.lateAlertMinutes) * 60
        let upcoming = watcher.meetings(from: now.addingTimeInterval(-late),
                                        to: now.addingTimeInterval(lead + 1), config: config)
        for m in upcoming where alerted[m.key] == nil
            && m.start > now.addingTimeInterval(-late)
            && m.start.timeIntervalSince(now) <= lead
            && !isAlreadyHandling(m) {
            alerted[m.key] = m.start
            enqueue(m)
        }
        alerted = alerted.filter { $0.value > now.addingTimeInterval(-3600) }
        updateIcon()
    }

    /// Keeps the Mac awake (lid open or closed) from a few minutes before an alert until it's handled,
    /// and schedules wake-ups before upcoming meetings in case it's already asleep.
    func updateLidMode(_ now: Date) {
        guard config.stayAwakeWithLidClosed, Power.enabled else { Power.keepAwake(false); return }
        let window = (config.leadMinutes + config.wakeMinutesBefore) * 60
        let next12h = watcher.meetings(from: now, to: now.addingTimeInterval(12 * 3600), config: config)
        let soon = next12h.contains { $0.start > now && $0.start.timeIntervalSince(now) <= window }
        // Safety cap: never hold the Mac awake more than 15 min past a meeting's start.
        let alertActive = alerts.current.map { $0.start > now.addingTimeInterval(-900) } ?? false
        Power.keepAwake(soon || alertActive || !queue.isEmpty || pendingSnoozes > 0)
        for m in next12h { Power.scheduleWake(at: m.start.addingTimeInterval(-window)) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Power.reset()
    }

    /// True if this meeting (same event + occurrence) is already on screen or waiting, even if its time was edited.
    func isAlreadyHandling(_ m: Meeting) -> Bool {
        guard !m.eventID.isEmpty else { return false }
        let same: (Meeting) -> Bool = { $0.eventID == m.eventID && $0.occurrence == m.occurrence }
        return (alerts.current.map(same) ?? false) || queue.contains(where: same)
    }

    func enqueue(_ m: Meeting) {
        if alerts.isShowing { queue.append(m) } else { alerts.show(m) }
    }

    func showNextQueued() {
        guard !queue.isEmpty else { return }
        alerts.show(queue.removeFirst())
    }

    func updateIcon() {
        let paused = (pausedUntil ?? .distantPast) > Date()
        statusItem.button?.title = paused ? "⏸" : "⏰"
    }

    // MARK: Menu

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func buildMenu() {
        menu.delegate = self
        nextItem.isEnabled = false
        menu.addItem(nextItem)
        menu.addItem(.separator())
        menu.addItem(item("Test alert now", #selector(testAlert)))
        pauseItem = item("Pause alerts for 1 hour", #selector(togglePause))
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(item("Open acknowledgement log", #selector(openLog)))
        menu.addItem(item("Edit settings…", #selector(openConfig)))
        menu.addItem(item("Reload settings", #selector(reloadConfig)))
        menu.addItem(.separator())
        menu.addItem(item("Uninstall MeetingNag…", #selector(uninstallApp)))
        menu.addItem(item("Quit MeetingNag", #selector(quit)))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let now = Date()
        let next = watcher.meetings(from: now, to: now.addingTimeInterval(24 * 3600), config: config)
            .first { $0.start > now }
        if let n = next {
            nextItem.title = "Next: \(n.title) at \(timeString(n.start))"
        } else {
            nextItem.title = watcher.hasAccess ? "No meetings in the next 24h" : "No calendar access"
        }
        let paused = (pausedUntil ?? .distantPast) > now
        pauseItem.title = paused ? "Resume alerts (paused until \(timeString(pausedUntil!)))" : "Pause alerts for 1 hour"
    }

    @objc func testAlert() {
        let now = Date()
        enqueue(Meeting(key: "test-\(now.timeIntervalSince1970)", eventID: "",
                        occurrence: now.addingTimeInterval(150), title: "Test meeting",
                        start: now.addingTimeInterval(150), end: now.addingTimeInterval(1950),
                        calendarName: "Test", joinURL: nil))
    }

    @objc func togglePause() {
        if (pausedUntil ?? .distantPast) > Date() { pausedUntil = nil } else { pausedUntil = Date().addingTimeInterval(3600) }
        updateIcon()
    }

    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.log.path) {
            try? "logged_at,meeting,meeting_start,action,seconds_after_alert\n"
                .write(to: Paths.log, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.log)
    }

    @objc func openConfig() {
        _ = Config.load() // ensures the file exists
        NSWorkspace.shared.open([Paths.config],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func reloadConfig() {
        config = Config.load()
        alerts.config = config
        poll()
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func uninstallApp() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Uninstall MeetingNag?"
        a.informativeText = "This removes the app, its login item and lid-closed mode. Your settings and acknowledgement log are kept. macOS will ask for your password."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn,
              let script = Bundle.main.path(forResource: "uninstall", ofType: "sh") else { return }
        Power.reset()
        let shell = "/bin/bash '\(script)' '\(NSUserName())'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(shell)\" with administrator privileges"]
        try? p.run()
    }

    func showNoAccess() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "MeetingNag needs calendar access"
        a.informativeText = "Open System Settings › Privacy & Security › Calendars, turn on MeetingNag (Full Access), then relaunch it."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn,
           let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(u)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// launchctl/uninstall send SIGTERM, which skips applicationWillTerminate — make sure lid sleep is restored.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { Power.reset(); exit(0) }
sigterm.resume()

app.run()
