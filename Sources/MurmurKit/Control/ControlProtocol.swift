import Foundation

/// Line-delimited JSON over the unix control socket (SPEC §10.2). One request line in, one
/// response line out. Deliberately loose/dictionary-based: murmurctl and the test harness are
/// the only clients, and forward/backward compat matters more than type ceremony.
public enum ControlProtocol {
    public struct Request: Sendable {
        public var cmd: String
        public var wav: String?
        public var id: String?
        public var state: String?
        public var timeoutMs: Int?
        public var kind: String?
        public var value: String?
        public var realtime: Bool?

        public init?(jsonLine: Data) {
            guard let obj = (try? JSONSerialization.jsonObject(with: jsonLine)) as? [String: Any],
                let cmd = obj["cmd"] as? String
            else { return nil }
            self.cmd = cmd
            self.wav = obj["wav"] as? String
            self.id = obj["id"] as? String
            self.state = obj["state"] as? String
            self.timeoutMs = obj["timeoutMs"] as? Int
            self.kind = obj["kind"] as? String
            self.value = obj["value"] as? String
            self.realtime = obj["realtime"] as? Bool
        }

        public init(cmd: String) {
            self.cmd = cmd
        }

        public func encoded() -> Data {
            var obj: [String: Any] = ["cmd": cmd]
            if let wav { obj["wav"] = wav }
            if let id { obj["id"] = id }
            if let state { obj["state"] = state }
            if let timeoutMs { obj["timeoutMs"] = timeoutMs }
            if let kind { obj["kind"] = kind }
            if let value { obj["value"] = value }
            if let realtime { obj["realtime"] = realtime }
            return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        }
    }

    public static func ok(_ payload: [String: Any] = [:]) -> [String: Any] {
        var obj = payload
        obj["ok"] = true
        return obj
    }

    public static func fail(_ error: String) -> [String: Any] {
        ["ok": false, "error": error]
    }

    public static func encodeResponse(_ obj: [String: Any]) -> Data {
        var data =
            (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"unencodable response"}"#.utf8)
        data.append(0x0A)
        return data
    }

    public static func metaDict(_ m: SessionMeta) -> [String: Any] {
        var d: [String: Any] = [
            "id": m.id,
            "state": m.state.rawValue,
            "attempts": m.attempts,
            "model": m.model,
        ]
        if let f = m.failureClass { d["failureClass"] = f.rawValue }
        if let e = m.lastError { d["lastError"] = e }
        if let s = m.durationSec { d["durationSec"] = s }
        if let t = m.transcript { d["transcript"] = t }
        return d
    }
}
