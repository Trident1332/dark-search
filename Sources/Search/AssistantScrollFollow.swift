import SwiftUI
import AppKit

/// User scrolling owns the reading position. Streamed growth may follow only
/// while the person is at the bottom; programmatic bounds changes do not
/// change that choice. Coalesce follow requests to one per display interval.
@MainActor
final class AssistantScrollFollow: ObservableObject {
    private(set) var following = true
    private var pending: Task<Void, Never>?

    func userScrolled(distanceFromBottom: CGFloat) {
        following = distanceFromBottom <= 32
        if !following { cancel() }
    }
    func resume() { following = true }
    func cancel() { pending?.cancel(); pending = nil }
    func schedule(_ scroll: @escaping @MainActor () -> Void) {
        guard following, pending == nil else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            if self.following { scroll() }
        }
    }
    deinit { pending?.cancel() }
}

struct AssistantScrollObserver: NSViewRepresentable {
    let follow: AssistantScrollFollow
    func makeNSView(context: Context) -> AssistantScrollTrackingView {
        let view = AssistantScrollTrackingView()
        view.follow = follow
        return view
    }
    func updateNSView(_ view: AssistantScrollTrackingView, context: Context) {
        view.follow = follow
        view.attach()
    }
    static func dismantleNSView(_ view: AssistantScrollTrackingView, coordinator: ()) { view.detach() }
}

final class AssistantScrollTrackingView: NSView {
    weak var follow: AssistantScrollFollow?
    private weak var scroll: NSScrollView?
    private var observation: NSObjectProtocol?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
    func attach() {
        guard let candidate = enclosingScrollView, candidate !== scroll else { return }
        detach()
        scroll = candidate
        observation = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: candidate, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scroll = self.scroll, let document = scroll.documentView else { return }
                let visible = scroll.contentView.bounds
                let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
                self.follow?.userScrolled(distanceFromBottom: max(0, distance))
            }
        }
    }
    func detach() {
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil; scroll = nil
    }
    deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
}
