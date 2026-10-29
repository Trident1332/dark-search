import AppKit
import Foundation
import Network
import WebKit
import XCTest
@testable import Search

/// A real WebKit check for TURN/TCP parsing and transport. Only a synthetic
/// loopback Allocate request is sent; no microphone, SIP or external ICE host.
@MainActor
final class DialerTurnCompatibilityTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "dialer-turn-compatibility-\(getpid())", 1)
        super.setUp()
    }

    func testWebKitRelayOnlyTURNOverTCPReachesLoopbackWithoutMicrophone() async throws {
        try XCTSkipUnless(Store.testing)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let listener = try TurnAllocateListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-turn-compatibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("index.html")
        try "<!doctype html><title>TURN compatibility</title><p>Loopback only</p>".write(to: file, atomically: true, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        defer { web.stopLoading(); window.contentView = nil; window.close() }
        web.loadFileURL(file, allowingReadAccessTo: folder)
        let deadline = Date().addingTimeInterval(8)
        while web.title != "TURN compatibility", Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(web.title, "TURN compatibility")
        let result: Any = try await withCheckedThrowingContinuation { done in
            web.callAsyncJavaScript(Self.probe, arguments: ["port": Int(port)], in: nil, in: .page) { result in
                done.resume(with: result)
            }
        }
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["accepted"] as? Bool, true, "TURN ?transport=tcp must survive WebKit URL validation: \(values["error"] ?? "")")
        XCTAssertEqual(values["policy"] as? String, "relay")
        XCTAssertEqual(values["url"] as? String, "turn:127.0.0.1:\(port)?transport=tcp")
        XCTAssertEqual(values["mediaRequests"] as? Int, 0)
        XCTAssertGreaterThan(listener.accepted, 0, "A successful constructor alone does not prove TCP transport")
        XCTAssertGreaterThan(listener.allocates, 0, "The listener must observe a TURN Allocate with the STUN magic cookie")
        let types = (values["candidates"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        XCTAssertTrue(types.allSatisfy { $0 == "relay" }, "No direct host or server-reflexive candidate is permitted")
    }

    // Adapted from the separate reviewed scratch probe. A data channel drives
    // ICE gathering, so there is no getUserMedia or permission requirement.
    private static let probe = """
    var url = 'turn:127.0.0.1:' + port + '?transport=tcp';
    var pc, timer, candidates = [], mediaRequests = 0;
    var original = navigator.mediaDevices && navigator.mediaDevices.getUserMedia;
    if (navigator.mediaDevices) navigator.mediaDevices.getUserMedia = function () {
      mediaRequests++; return Promise.reject(new Error('Microphone forbidden in TURN probe'));
    };
    try {
      pc = new RTCPeerConnection({iceTransportPolicy:'relay', iceCandidatePoolSize:0,
        iceServers:[{urls:url, username:'synthetic-probe', credential:'synthetic-probe'}]});
      var config = pc.getConfiguration();
      var urls = config.iceServers.length === 1 && config.iceServers[0].urls;
      if (typeof urls === 'string') urls = [urls];
      if (config.iceTransportPolicy !== 'relay' || config.iceCandidatePoolSize !== 0 ||
          !Array.isArray(urls) || urls.length !== 1 || urls[0] !== url) throw new Error('Relay-only configuration changed');
      var gathered = new Promise(function (resolve) {
        pc.onicecandidate = function (event) {
          if (event.candidate) candidates.push({type:event.candidate.type, protocol:event.candidate.protocol});
          else resolve('complete');
        };
        timer = setTimeout(function () { resolve('timeout'); }, 8000);
      });
      pc.createDataChannel('loopback-turn-probe');
      await pc.setLocalDescription(await pc.createOffer());
      var result = await gathered;
      return {accepted:true, policy:config.iceTransportPolicy, url:url, result:result,
              candidates:candidates, mediaRequests:mediaRequests};
    } catch (error) {
      return {accepted:false, error:String(error.name || 'Error') + ': ' + String(error.message || error), mediaRequests:mediaRequests};
    } finally {
      clearTimeout(timer);
      if (pc) pc.close();
      if (navigator.mediaDevices && original) navigator.mediaDevices.getUserMedia = original;
    }
    """
}

private final class TurnAllocateListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SearchTests.TurnAllocate")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var acceptedCount = 0
    private var allocateCount = 0
    var accepted: Int { lock.withLock { acceptedCount } }
    var allocates: Int { lock.withLock { allocateCount } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { done in
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.withLock { self.connections.append(connection); self.acceptedCount += 1 }
                connection.start(queue: self.queue)
                self.read(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.listener.stateUpdateHandler = nil; done.resume(returning: self.listener.port!.rawValue)
                case .failed(let error): self.listener.stateUpdateHandler = nil; done.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel(); lock.withLock { connections }.forEach { $0.cancel() } }

    private func read(_ connection: NWConnection, previous: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous
            if let data { bytes.append(data) }
            if bytes.count >= 20 {
                let length = 20 + Int(bytes[2]) * 256 + Int(bytes[3])
                if length <= bytes.count {
                    if bytes[0] == 0, bytes[1] == 3, Array(bytes[4..<8]) == [0x21, 0x12, 0xa4, 0x42] {
                        self.lock.withLock { self.allocateCount += 1 }
                    }
                    // No response or relay allocation: gathering times out and
                    // closes. The fixture cannot forward anything externally.
                    return
                }
            }
            if error == nil, !complete, bytes.count < 8192 { self.read(connection, previous: bytes) }
            else { connection.cancel() }
        }
    }
}
