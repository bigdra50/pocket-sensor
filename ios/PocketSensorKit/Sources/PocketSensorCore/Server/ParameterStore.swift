import Foundation

public struct ParameterStore: Equatable, Sendable {
    private var specs: [ParameterSpec]
    private var stored: [String: ParameterValue.Value]

    public init(specs: [ParameterSpec]) {
        self.specs = specs
        stored = [:]
        for spec in specs {
            stored[spec.name] = Self.defaultValue(spec)
        }
    }

    /// names が空なら定義順の全件。
    public func get(names: [String]) -> [ParameterValue] {
        let selected: [ParameterSpec]
        if names.isEmpty {
            selected = specs
        } else {
            let wanted = Set(names)
            selected = specs.filter { wanted.contains($0.name) }
        }
        return selected.compactMap { spec in
            stored[spec.name].map { ParameterValue(name: spec.name, value: $0) }
        }
    }

    /// 未知の名前、型違い、書き込み不可は無視する。数値は min...max へ丸める。
    public mutating func set(_ updates: [ParameterValue]) -> [ParameterValue] {
        apply(updates, bypassWritable: false)
    }

    /// `writable` を無視する。端末名のように画面からだけ変える値用。
    public mutating func setInternal(name: String, value: ParameterValue.Value) -> ParameterValue? {
        let changed = apply([ParameterValue(name: name, value: value)], bypassWritable: true)
        return changed.first
    }

    public func number(_ name: String) -> Double {
        guard case .number(let value)? = stored[name] else {
            preconditionFailure("parameter \(name) is not a number")
        }
        return value
    }

    public func string(_ name: String) -> String {
        guard case .string(let value)? = stored[name] else {
            preconditionFailure("parameter \(name) is not a string")
        }
        return value
    }

    private mutating func apply(_ updates: [ParameterValue], bypassWritable: Bool) -> [ParameterValue] {
        var changed: [ParameterValue] = []
        for update in updates {
            guard let spec = specs.first(where: { $0.name == update.name }) else { continue }
            if !spec.writable, !bypassWritable { continue }
            guard let next = normalized(update.value, spec: spec) else { continue }
            if stored[spec.name] != next {
                stored[spec.name] = next
                changed.append(ParameterValue(name: spec.name, value: next))
            }
        }
        return changed
    }

    private func normalized(_ value: ParameterValue.Value, spec: ParameterSpec) -> ParameterValue.Value? {
        switch (spec.type, value) {
        case (.number, .number(let raw)):
            var number = raw
            if let min = spec.min { number = max(min, number) }
            if let max = spec.max { number = min(max, number) }
            return .number(number)
        case (.boolean, .bool(let flag)):
            return .bool(flag)
        case (.string, .string(let text)):
            if let choices = spec.choices, !choices.contains(text) {
                return nil
            }
            return .string(text)
        default:
            return nil
        }
    }

    private static func defaultValue(_ spec: ParameterSpec) -> ParameterValue.Value {
        switch spec.type {
        case .number:
            return .number(spec.defaultNumber ?? 0)
        case .boolean:
            return .bool(spec.defaultBoolean ?? false)
        case .string:
            return .string(spec.defaultString ?? "")
        }
    }
}
