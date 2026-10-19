import Foundation
import Testing
@testable import Bridge

@Suite struct SuggestRouteTests {
    private func item(_ kind: Suggestions.Item.Kind, _ target: String, params: [String: JSONValue]? = nil) -> Suggestions.Item {
        .init(id: "x", kind: kind, title: "T", glyph: "T", reason: "r", target: target, params: params)
    }

    @Test func widgetURLRoundTripsTheID() throws {
        for id in ["app.wechat", "retry.j_01ABC", "lane.pll-moss", "cal.3f2a"] {
            let url = try #require(SuggestRoute.url(for: id))
            #expect(url.absoluteString == "bridge://suggest/\(id)")
            #expect(SuggestRoute.itemID(from: url) == id)
        }
    }

    @Test func otherURLsAreNotSuggestTaps() {
        for raw in ["bridge-widget://status", "bridge://other/app.wechat", "bridge://suggest", "bridge://suggest/",
                    "https://suggest/app.wechat"] {
            #expect(SuggestRoute.itemID(from: URL(string: raw)!) == nil, "\(raw)")
        }
    }

    @Test func appsAndURLsOpen() {
        #expect(SuggestRoute.action(for: item(.app, "weixin://")) == .open(URL(string: "weixin://")!))
        #expect(SuggestRoute.action(for: item(.url, "https://boringbox.dev/box/"))
                == .open(URL(string: "https://boringbox.dev/box/")!))
        #expect(SuggestRoute.action(for: item(.app, "not a url")) == nil)
    }

    @Test func capabilitiesAndShortcutsRunHere() {
        #expect(SuggestRoute.action(for: item(.capability, "location.now", params: ["accuracy": .string("best")]))
                == .capability("location.now", ["accuracy": .string("best")]))
        #expect(SuggestRoute.action(for: item(.capability, "device.info")) == .capability("device.info", [:]))
        #expect(SuggestRoute.action(for: item(.shortcut, "Morning")) == .shortcut("Morning"))
        #expect(SuggestRoute.action(for: item(.shortcut, "")) == nil)
    }

    @Test func decodesTheBoxReplyAndResolvesByID() throws {
        let json = """
        {"generated_at": "2026-10-19T08:30:00Z", "items": [
          {"id": "retry.j_1", "kind": "capability", "title": "Retry location.now", "glyph": "↻",
           "reason": "failed 12m", "target": "location.now", "params": {"accuracy": "best"}},
          {"id": "app.wechat", "kind": "app", "title": "WeChat", "glyph": "微", "reason": "app", "target": "weixin://"}
        ]}
        """
        let decoded = try Suggestions.decode(Data(json.utf8))
        #expect(decoded.items.count == 2)
        #expect(decoded.item(id: "retry.j_1")?.params == ["accuracy": .string("best")])
        #expect(decoded.item(id: "nope") == nil)
        #expect(try Suggestions.decode(try decoded.encoded()) == decoded)
    }

    @Test func tapRequestPostsDeviceAndID() throws {
        let client = BoxClient(config: BridgeConfig(baseURL: URL(string: "https://box.example")!, token: "t", deviceId: "my-iphone"))
        let request = try client.suggestTapRequest(id: "app.wechat")
        #expect(request.url?.absoluteString == "https://box.example/bridge/suggest/tap")
        #expect(request.httpMethod == "POST")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body == ["device": "my-iphone", "id": "app.wechat"])
    }
}
