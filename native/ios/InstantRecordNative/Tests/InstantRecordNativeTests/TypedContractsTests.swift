import Observation
import SwiftUI
import XCTest
@testable import InstantRecordNative

final class TypedContractsTests: XCTestCase {
    struct SampleProps: NativeProps, Codable, Equatable, Sendable {
        typealias Action = SampleAction
        static let componentName = "SampleView"

        struct Sender: Codable, Equatable, Sendable {
            let displayName: String
            let verified: Bool

            private enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case verified
            }
        }

        struct Item: Codable, Equatable, Sendable {
            let title: String
            let score: Double
            let sentAt: Date

            private enum CodingKeys: String, CodingKey {
                case title
                case score
                case sentAt = "sent_at"
            }
        }

        let title: String
        let unreadCount: Int
        let ratio: Double
        let archived: Bool
        let subtitle: String?
        let sender: Sender
        let items: [Item]
        let tags: [String]

        private enum CodingKeys: String, CodingKey {
            case title
            case unreadCount = "unread_count"
            case ratio
            case archived
            case subtitle
            case sender
            case items
            case tags
        }
    }

    enum SampleAction: NativeAction, Equatable, Sendable {
        case archive(id: String)
        case reply(body: String, urgent: Bool)

        var actionName: String {
            switch self {
            case .archive: "archive"
            case .reply: "reply"
            }
        }

        var actionArgs: [String: String] {
            switch self {
            case let .archive(id): ["id": id]
            case .reply: [:]
            }
        }

        var actionValues: [String: String] {
            switch self {
            case .archive: [:]
            case let .reply(body, urgent): ["body": body, "urgent": NativeWire.encode(urgent)]
            }
        }
    }

    @Observable
    final class SampleState: NativePropsState {
        typealias Props = SampleProps

        private(set) var title: String
        private(set) var unreadCount: Int
        private(set) var snapshot: SampleProps
        @ObservationIgnored private let actions: TypedActions<SampleAction>

        init(props: SampleProps, actions: TypedActions<SampleAction>) {
            self.title = props.title
            self.unreadCount = props.unreadCount
            self.snapshot = props
            self.actions = actions
        }

        func apply(_ props: SampleProps) {
            guard snapshot != props else { return }
            if title != props.title { title = props.title }
            if unreadCount != props.unreadCount { unreadCount = props.unreadCount }
            snapshot = props
        }

        func send(_ action: SampleAction) {
            actions.send(action)
        }
    }

    private static func node(_ kind: String, id: String = "", text: String = "", props: [String: String] = [:], _ children: [String] = []) -> String {
        func strings(_ value: [String: String]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        let quoted = [kind, id, text].map { String(decoding: (try? JSONSerialization.data(withJSONObject: [$0])) ?? Data(), as: UTF8.self).dropFirst().dropLast() }
        return "{\"kind\":\(quoted[0]),\"id\":\(quoted[1]),\"text\":\(quoted[2]),\"action\":\"\",\"params\":{},\"args\":{},\"props\":\(strings(props)),\"children\":[\(children.joined(separator: ","))]}"
    }

    private func sampleNode(unread: String = "4", subtitle: String? = nil) throws -> Node {
        var children = [
            Self.node("prop", text: "Support", props: ["name": "title", "type": "string"]),
            Self.node("prop", text: unread, props: ["name": "unread_count", "type": "int"]),
            Self.node("prop", text: "0.75", props: ["name": "ratio", "type": "float"]),
            Self.node("prop", text: "false", props: ["name": "archived", "type": "bool"]),
            Self.node("record", props: ["name": "sender"], [
                Self.node("prop", text: "Rae", props: ["name": "display_name", "type": "string"]),
                Self.node("prop", text: "true", props: ["name": "verified", "type": "bool"]),
            ]),
            Self.node("props", props: ["name": "items"], [
                Self.node("record", [
                    Self.node("prop", text: "Night shift", props: ["name": "title", "type": "string"]),
                    Self.node("prop", text: "9.5", props: ["name": "score", "type": "float"]),
                    Self.node("prop", text: "2026-11-19T06:21:00.123456Z", props: ["name": "sent_at", "type": "date"]),
                ]),
            ]),
            Self.node("props", props: ["name": "tags"], [
                Self.node("prop", text: "urgent", props: ["type": "string"]),
                Self.node("prop", text: "billing", props: ["type": "string"]),
            ]),
        ]
        if let subtitle {
            children.append(Self.node("prop", text: subtitle, props: ["name": "subtitle", "type": "string"]))
        }
        return try Node(json: Self.node("swift", text: "SampleView", children))
    }

    private func host(_ views: Screens = Screens(), engine: FakeEngine = FakeEngine()) -> AppHost {
        AppHost(engine: engine, root: Route("mailbox", ["member": "maya"]), views: views, store: { _ in AppHost.Store(database: "", endpoint: "") },
                exchange: { _ in "200\n" }, clock: ManualClock(), reachability: ManualReachability())
    }

    func testPropsDecodesTypedCodableStructWithNestedObjectsListsDatesAndOptionals() throws {
        let props = Props(try sampleNode())
        let decoded = try props.decode(SampleProps.self)

        XCTAssertEqual("Support", decoded.title)
        XCTAssertEqual(4, decoded.unreadCount)
        XCTAssertEqual(0.75, decoded.ratio)
        XCTAssertFalse(decoded.archived)
        XCTAssertNil(decoded.subtitle)
        XCTAssertEqual(SampleProps.Sender(displayName: "Rae", verified: true), decoded.sender)
        XCTAssertEqual(1, decoded.items.count)
        XCTAssertEqual("Night shift", decoded.items[0].title)
        XCTAssertEqual(9.5, decoded.items[0].score)
        XCTAssertEqual(Moment.date("2026-11-19T06:21:00.123456Z"), decoded.items[0].sentAt)
        XCTAssertEqual(["urgent", "billing"], decoded.tags)
        XCTAssertEqual(0.75, props.double("ratio"))
        XCTAssertEqual("Rae", props.nested("sender")?["display_name"])

        let withSubtitle = try Props(try sampleNode(subtitle: "Team inbox")).decode(SampleProps.self)
        XCTAssertEqual("Team inbox", withSubtitle.subtitle)
    }

    func testPropsDecodeFailsClearlyOnMalformedTypedValues() throws {
        let broken = Props(try sampleNode(unread: "not-a-number"))
        XCTAssertThrowsError(try broken.decode(SampleProps.self)) { error in
            XCTAssertEqual(PropsDecodingError.invalidValue(name: "unread_count", expected: "int", actual: "not-a-number"), error as? PropsDecodingError)
        }
    }

    @MainActor
    func testTypedRegistrationDecodesPropsAndDispatchesArgsAndValues() throws {
        let engine = FakeEngine()
        var capturedProps: SampleProps?
        var capturedActions: TypedActions<SampleAction>?
        var views = Screens()
        views.register(SampleProps.self) { props, actions in
            capturedProps = props
            capturedActions = actions
            return Text(props.title)
        }

        let host = host(views, engine: engine)
        let rendered = ImageRenderer(content: NodeView(node: try sampleNode(), route: host.root, host: host))
        XCTAssertNotNil(rendered.cgImage)
        XCTAssertEqual(4, capturedProps?.unreadCount)

        capturedActions?.send(.archive(id: "m2"))
        capturedActions?(.reply(body: "On it", urgent: true))
        host.settle()

        let actions = engine.calls.filter { $0.hasPrefix("action") }
        XCTAssertEqual([
            "action mailbox member=maya archive id=m2",
            "action mailbox member=maya reply  values body=On it,urgent=true",
        ], actions)
    }

    @MainActor
    func testTypedRegistrationRendersDiagnosticFallbackOnDecodeFailure() throws {
        var views = Screens()
        views.register(SampleProps.self) { props, _ in Text(props.title) }
        let host = host(views)

        let rendered = ImageRenderer(content: NodeView(node: try sampleNode(unread: "oops"), route: host.root, host: host))
        XCTAssertNotNil(rendered.cgImage)
    }

    @MainActor
    func testObservableStateRegistrationAppliesNewSnapshotsInPlace() throws {
        let engine = FakeEngine()
        var observedState: SampleState?
        var views = Screens()
        views.register(state: SampleState.self) { state in
            observedState = state
            return Text("\(state.title): \(state.unreadCount)")
        }

        let host = host(views, engine: engine)
        XCTAssertNotNil(ImageRenderer(content: NodeView(node: try sampleNode(unread: "4"), route: host.root, host: host)).cgImage)

        let state = try XCTUnwrap(observedState)
        XCTAssertEqual(4, state.unreadCount)

        let next = try Props(try sampleNode(unread: "9")).decode(SampleProps.self)
        state.apply(next)
        XCTAssertEqual(9, state.unreadCount)
        XCTAssertEqual(next, state.snapshot)

        state.send(.archive(id: "m9"))
        host.settle()
        XCTAssertEqual(["action mailbox member=maya archive id=m9"], engine.calls.filter { $0.hasPrefix("action") })
    }

    func testNativeWireEncodesPrimitiveAndDateActionParameters() {
        XCTAssertEqual("hello", NativeWire.encode("hello"))
        XCTAssertEqual("42", NativeWire.encode(42))
        XCTAssertEqual("3.5", NativeWire.encode(3.5))
        XCTAssertEqual("true", NativeWire.encode(true))
        XCTAssertEqual("false", NativeWire.encode(false))
        let moment = Moment.date("2026-11-19T06:21:00.000Z")!
        XCTAssertEqual(moment, Moment.date(NativeWire.encode(moment)))
    }
}
