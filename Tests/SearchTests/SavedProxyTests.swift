import AppKit
import XCTest
@testable import Search

@MainActor
final class SavedProxyTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE","saved-proxies-\(getpid())",1)
        super.setUp()
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        _ = Shared.prefs
        Proxy.shared.automaticTarget=nil
        Proxy.shared.take(ProxySetup())
        for key in Store.settings.dictionaryRepresentation().keys where key.hasPrefix("proxy.") { Store.settings.removeObject(forKey:key) }
        Store.settings.set(false,forKey:"proxy.blocks")
        Store.settings.set(false,forKey:"proxy.timeZone")
        ConnectionPasswords.useBackendForTesting(nil,enabled:false)
    }
    override func tearDown() async throws {
        Proxy.shared.take(ProxySetup())
        ConnectionPasswords.useBackendForTesting(nil)
        for _ in 0..<200 where Proxy.shared.changingContent { try await Task.sleep(for:.milliseconds(10)) }
    }
    private func connection(_ name: String, port: String = "8080") -> SavedProxy {
        SavedProxy(name:name,kind:.http,host:"127.0.0.1",port:port,signsIn:true,user:"test-\(name)")
    }
    func testExistingConfigurationMigratesWithoutReadingOrReplacingItsPassword() {
        let old=connection("legacy")
        XCTAssertTrue(ProxyPassword.save("synthetic-original",for:old.setup))
        Store.settings.set(old.host,forKey:"proxy.host"); Store.settings.set(old.kind.rawValue,forKey:"proxy.kind")
        Store.settings.set(old.port,forKey:"proxy.port"); Store.settings.set(old.user,forKey:"proxy.user")
        Store.settings.set(true,forKey:"proxy.signsIn")
        let prefs=Preferences()
        XCTAssertEqual(prefs.savedProxies.count,1)
        XCTAssertEqual(prefs.savedProxies.first?.host,old.host)
        XCTAssertEqual(prefs.selectedProxyID,prefs.savedProxies.first?.id)
        XCTAssertEqual(ProxyPassword.read(prefs.proxySetup),"synthetic-original")
        let saved=String(decoding:Store.settings.data(forKey:SavedProxyLibrary.key)!,as:UTF8.self)
        XCTAssertFalse(saved.contains("synthetic-original"))
    }
    func testSwitchAppliesOneCompleteRouteAndKeepsEachPassword() {
        let prefs=Preferences(), a=connection("A"),b=connection("B",port:"8081")
        XCTAssertTrue(ProxyPassword.save("synthetic-A",for:a.setup))
        XCTAssertTrue(ProxyPassword.save("synthetic-B",for:b.setup))
        prefs.saveProxy(a); prefs.saveProxy(b)
        prefs.selectProxy(a.id,connect:true)
        let revision=Proxy.shared.revision
        prefs.selectProxy(b.id)
        XCTAssertEqual(Proxy.shared.revision,revision+1)
        XCTAssertEqual(Proxy.shared.setup.host,b.host)
        XCTAssertEqual(Proxy.shared.setup.port,8081)
        XCTAssertEqual(Proxy.shared.setup.user,b.user)
        XCTAssertEqual(ProxyPassword.read(Proxy.shared.setup),"synthetic-B")
        XCTAssertTrue(prefs.proxyOn)
        prefs.selectProxy(a.id)
        XCTAssertEqual(ProxyPassword.read(Proxy.shared.setup),"synthetic-A")
    }
    func testInactiveSaveDoesNotTouchTheCurrentRouteAndSelectionDoesNotEnableAnOffProxy() {
        let prefs=Preferences(),a=connection("A"),b=connection("B")
        prefs.saveProxy(a);prefs.selectProxy(a.id)
        let revision=Proxy.shared.revision
        prefs.saveProxy(b)
        XCTAssertEqual(Proxy.shared.revision,revision)
        XCTAssertEqual(prefs.selectedProxyID,a.id)
        XCTAssertFalse(prefs.proxyOn)
        prefs.selectProxy(b.id)
        XCTAssertFalse(prefs.proxyOn)
    }
    func testSelectedConnectionEditsAndSelectionSurviveRecreation() {
        let prefs=Preferences(),a=connection("A"),b=connection("B")
        prefs.saveProxy(a);prefs.saveProxy(b);prefs.selectProxy(b.id)
        prefs.proxyHost="updated.example";prefs.proxyPort="3128"
        XCTAssertEqual(prefs.savedProxies.first(where:{$0.id==b.id})?.host,"updated.example")
        let restarted=Preferences()
        XCTAssertEqual(restarted.selectedProxyID,b.id)
        XCTAssertEqual(restarted.proxyHost,"updated.example")
        XCTAssertEqual(restarted.proxyPort,"3128")
        XCTAssertEqual(restarted.savedProxies.count,2)
    }
    func testLibraryWinsOverPartiallyUpdatedLegacyKeys() {
        let prefs=Preferences(),a=connection("A"),b=connection("B",port:"8081")
        prefs.saveProxy(a);prefs.saveProxy(b);prefs.selectProxy(b.id)
        Store.settings.set(a.user,forKey:"proxy.user")
        Store.settings.set(a.port,forKey:"proxy.port")
        let restarted=Preferences()
        XCTAssertEqual(restarted.proxyUser,b.user)
        XCTAssertEqual(restarted.proxyPort,b.port)
    }
    func testRenameAndRemoveNeverDisconnectOrForgetCredentials() {
        let prefs=Preferences();var a=connection("A")
        prefs.saveProxy(a);prefs.selectProxy(a.id,connect:true)
        XCTAssertTrue(ProxyPassword.save("synthetic-kept",for:a.setup))
        let revision=Proxy.shared.revision
        a.name="Renamed";prefs.saveProxy(a)
        XCTAssertEqual(Proxy.shared.revision,revision)
        prefs.removeProxy(a.id)
        XCTAssertTrue(prefs.savedProxies.isEmpty)
        XCTAssertNil(prefs.selectedProxyID)
        XCTAssertTrue(prefs.proxyOn)
        XCTAssertEqual(Proxy.shared.revision,revision)
        XCTAssertEqual(ProxyPassword.read(prefs.proxySetup),"synthetic-kept")
        let restarted=Preferences()
        XCTAssertTrue(restarted.savedProxies.isEmpty)
        XCTAssertEqual(restarted.proxyHost,a.host)
    }
    func testInvalidSelectionAndMalformedLibraryCannotEraseTheOldConnection() {
        let old=connection("Legacy")
        let library=SavedProxyLibrary.load(Data("invalid".utf8),legacy:old)
        XCTAssertEqual(library.entries,[old])
        let prefs=Preferences(),revision=Proxy.shared.revision
        prefs.selectProxy(UUID(),connect:true)
        XCTAssertEqual(Proxy.shared.revision,revision)
        XCTAssertFalse(prefs.proxyOn)
        XCTAssertFalse(SavedProxy(host:"",port:"8080").valid)
        XCTAssertFalse(SavedProxy(host:"example",port:"0").valid)
        XCTAssertFalse(SavedProxy(host:"example",port:"65536").valid)
        XCTAssertTrue(SavedProxy(host:"example",port:"").valid)
    }

    func testOneLineReplacesTheSelectedEndpointAtomicallyAndKeepsPrivacyOptions() throws {
        let prefs = Preferences(), original = connection("My connection")
        prefs.saveProxy(original); prefs.selectProxy(original.id, connect: true)
        prefs.proxyBlocks = true
        prefs.proxyMatchesTimeZone = true
        let revision = Proxy.shared.revision
        let line = try ProxyLine.parse("new.example:1080:account,mobile:synthetic-new-password", kind: .socks5)
        XCTAssertTrue(prefs.applyProxyLine(line))
        XCTAssertEqual(Proxy.shared.revision, revision + 1)
        XCTAssertTrue(prefs.proxyOn)
        XCTAssertTrue(prefs.proxyBlocks)
        XCTAssertTrue(prefs.proxyMatchesTimeZone)
        XCTAssertEqual(prefs.selectedProxyID, original.id)
        XCTAssertEqual(prefs.savedProxies.first?.name, original.name)
        XCTAssertEqual(prefs.savedProxies.first?.host, "new.example")
        XCTAssertEqual(prefs.proxyUser, "account,mobile")
        XCTAssertEqual(ProxyPassword.read(prefs.proxySetup), "synthetic-new-password")
        XCTAssertFalse(String(describing: Store.settings.dictionaryRepresentation()).contains("synthetic-new-password"))
        let restored = Preferences()
        XCTAssertEqual(restored.proxySetup, prefs.proxySetup)
        XCTAssertEqual(ProxyPassword.read(restored.proxySetup), "synthetic-new-password")
    }

    func testOneLineWhileOffDoesNotEnableProxyAndCanRemoveAuthentication() throws {
        let prefs = Preferences()
        XCTAssertTrue(prefs.applyProxyLine(try ProxyLine.parse("host.example:8080:user:synthetic-secret", kind: .http)))
        XCTAssertFalse(prefs.proxyOn)
        XCTAssertTrue(prefs.proxySignsIn)
        XCTAssertTrue(prefs.applyProxyLine(try ProxyLine.parse("another.example:1080", kind: .socks5)))
        XCTAssertFalse(prefs.proxyOn)
        XCTAssertFalse(prefs.proxySignsIn)
        XCTAssertEqual(prefs.proxyUser, "")
        XCTAssertEqual(prefs.proxyKind, .socks5)
    }

    func testOneLineVaultFailureLeavesCurrentRouteAndSavedEntryIntact() throws {
        let prefs = Preferences(), original = connection("Original")
        prefs.saveProxy(original); prefs.selectProxy(original.id)
        let before = prefs.proxySetup, revision = Proxy.shared.revision
        ConnectionPasswords.useBackendForTesting(.init(read: { _ in .missing }, save: { _, _ in throw CocoaError(.fileWriteNoPermission) }, forget: { _ in }), enabled: true)
        let line = try ProxyLine.parse("other.example:1080:user:synthetic-secret", kind: .socks5)
        XCTAssertFalse(prefs.applyProxyLine(line))
        XCTAssertEqual(prefs.proxySetup, before)
        XCTAssertEqual(Proxy.shared.revision, revision)
        XCTAssertEqual(prefs.savedProxies, [original])
    }

    func testOneLineReplacingOnlyPasswordRearmsExactlyOnce() throws {
        let prefs = Preferences()
        XCTAssertTrue(prefs.applyProxyLine(try ProxyLine.parse("host.example:1080:user:synthetic-first", kind: .socks5)))
        let revision = Proxy.shared.revision
        XCTAssertTrue(prefs.applyProxyLine(try ProxyLine.parse("host.example:1080:user:synthetic-second", kind: .socks5)))
        XCTAssertEqual(Proxy.shared.revision, revision + 1)
        XCTAssertEqual(ProxyPassword.read(prefs.proxySetup), "synthetic-second")
        XCTAssertFalse(prefs.proxyOn)
    }
}
