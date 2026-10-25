import Foundation
import MacAmbientJevEngineProtocol

final class EngineProtocolCoverageRecorder {
    enum Phase: Equatable {
        case required
        case observed
    }

    private(set) var requiredTokens: Set<String> = []
    private(set) var observedTokens: Set<String> = []
    private var requiredEncodedTypes: Set<ObjectIdentifier> = []
    private var requiredTypeObligations: Set<ObjectIdentifier> = []
    private var typeNames: [ObjectIdentifier: String] = [:]
    var failure: Error?

    func recordEncodedType(_ type: any Encodable.Type, displayName: String, phase: Phase) {
        guard phase == .required else { return }
        let identity = ObjectIdentifier(type)
        typeNames[identity] = displayName
        requiredEncodedTypes.insert(identity)
    }

    func recordTypeObligation(_ type: any Encodable.Type, displayName: String, phase: Phase) {
        guard phase == .required else { return }
        let identity = ObjectIdentifier(type)
        typeNames[identity] = displayName
        requiredTypeObligations.insert(identity)
    }

    func coverageIssues() -> [String] {
        var issues = requiredTokens.subtracting(observedTokens).map {
            "Missing wire corpus coverage: \($0)"
        }
        issues += observedTokens.subtracting(requiredTokens).map {
            "Unregistered wire corpus token: \($0)"
        }
        issues += requiredTypeObligations.subtracting(requiredEncodedTypes).map { identity in
            "Missing non-nil representative for wire type: \(typeNames[identity]!)"
        }
        return issues.sorted()
    }

    func recordKey(owner: String, key: String, phase: Phase) {
        let token = "key \(owner).\(key)"
        switch phase {
        case .required:
            requiredTokens.insert(token)
        case .observed:
            observedTokens.insert(token)
        }
    }

    func recordEnum(type: String, value: String, phase: Phase) {
        let token = "enum \(type)=\(value)"
        switch phase {
        case .required:
            requiredTokens.insert(token)
        case .observed:
            observedTokens.insert(token)
        }
    }

    func recordNullable(owner: String, key: String, isNull: Bool, phase: Phase) {
        let arm = isNull ? "null" : "non-null"
        let token = "nullable \(owner).\(key)=\(arm)"
        switch phase {
        case .required:
            requiredTokens.insert("nullable \(owner).\(key)=null")
            requiredTokens.insert("nullable \(owner).\(key)=non-null")
        case .observed:
            observedTokens.insert(token)
        }
    }

    func recordRequiredToken(_ token: String) {
        requiredTokens.insert(token)
    }

    func recordObservedToken(_ token: String) {
        observedTokens.insert(token)
    }

    func recordFailure(_ error: Error) {
        if failure == nil {
            failure = error
        }
    }

    func checkForFailure() throws {
        if let failure {
            throw failure
        }
    }
}

private protocol EngineNullableCoverageValue {
    static var wrappedType: any Encodable.Type { get }
    var isNull: Bool { get }
}

extension EngineNullable: EngineNullableCoverageValue {
    fileprivate static var wrappedType: any Encodable.Type { Value.self }
    fileprivate var isNull: Bool { wrappedValue == nil }
}

private protocol EngineOptionalCoverageValue {
    static var wrappedType: any Encodable.Type { get }
    var hasValue: Bool { get }
}

extension Optional: EngineOptionalCoverageValue where Wrapped: Encodable {
    fileprivate static var wrappedType: any Encodable.Type { Wrapped.self }
    fileprivate var hasValue: Bool { self != nil }
}

private protocol EngineArrayCoverageValue {
    static var elementType: any Encodable.Type { get }
    var isEmpty: Bool { get }
}

extension Array: EngineArrayCoverageValue where Element: Encodable {
    fileprivate static var elementType: any Encodable.Type { Element.self }
    fileprivate var isEmpty: Bool { count == 0 }
}

private enum EngineCoverageEncodingError: Error, CustomStringConvertible {
    case keysNotCaseIterable(String)
    case unreadableOwner(String)
    case unreadableTypeName(String)
    case unsupportedEnum(String, String)
    case rawRepresentableNotCaseIterable(String)
    case untypedWireDiscriminator(String)
    case nullableWithoutField(String)
    case multipleContainers(String, String, String)

    var description: String {
        switch self {
        case let .keysNotCaseIterable(type):
            "CodingKeys type is not CaseIterable: \(type)"
        case let .unreadableOwner(type):
            "Could not derive a stable CodingKeys owner from \(type)"
        case let .unreadableTypeName(type):
            "Could not derive a stable Swift type name from \(type)"
        case let .unsupportedEnum(type, encoded):
            "CaseIterable Encodable type is not a scalar JSON enum: \(type) encoded as \(encoded)"
        case let .rawRepresentableNotCaseIterable(type):
            "RawRepresentable wire type is not CaseIterable: \(type)"
        case let .untypedWireDiscriminator(owner):
            "Untyped wire discriminator: \(owner).kind must encode a CaseIterable enum, not String"
        case let .nullableWithoutField(type):
            "EngineNullable was encoded without a declaring keyed field: \(type)"
        case let .multipleContainers(path, first, second):
            "Encoder at \(path) requested both \(first) and \(second) containers"
        }
    }
}

fileprivate struct EngineNullableField {
    let owner: String
    let key: String
}

/// A traversal-only Encoder. It deliberately emits no bytes: Codable implementations
/// themselves provide the key and typed-value calls that define wire coverage.
final class EngineProtocolCoverageEncoder: Encoder {
    private let recorder: EngineProtocolCoverageRecorder
    private let phase: EngineProtocolCoverageRecorder.Phase
    private let nullableField: EngineNullableField?
    private var claimedContainer: String?

    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    private init(
        recorder: EngineProtocolCoverageRecorder,
        phase: EngineProtocolCoverageRecorder.Phase,
        codingPath: [any CodingKey],
        nullableField: EngineNullableField?
    ) {
        self.recorder = recorder
        self.phase = phase
        self.codingPath = codingPath
        self.nullableField = nullableField
    }

    static func traverse<T: Encodable>(
        _ value: T,
        recorder: EngineProtocolCoverageRecorder,
        phase: EngineProtocolCoverageRecorder.Phase
    ) throws {
        let encoder = EngineProtocolCoverageEncoder(
            recorder: recorder, phase: phase, codingPath: [], nullableField: nil
        )
        try encoder.encodeGeneric(value, nullableField: nil)
        try recorder.checkForFailure()
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        claimContainer("keyed")
        let reflected = String(reflecting: Key.self)
        let owner = Self.stableOwner(from: reflected)
        guard let names = Self.caseIterableCodingKeys(type) else {
            recorder.recordFailure(EngineCoverageEncodingError.keysNotCaseIterable(reflected))
            return KeyedEncodingContainer(EngineCoverageKeyedContainer(encoder: self, owner: owner))
        }
        guard let owner else {
            recorder.recordFailure(EngineCoverageEncodingError.unreadableOwner(reflected))
            return KeyedEncodingContainer(EngineCoverageKeyedContainer(encoder: self, owner: nil))
        }
        if phase == .required {
            // Coverage is per declaring type, not envelope occurrence; register its full key set during schema discovery only.
            for name in names {
                recorder.recordKey(owner: owner, key: name, phase: .required)
            }
        }
        return KeyedEncodingContainer(EngineCoverageKeyedContainer(encoder: self, owner: owner))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        claimContainer("unkeyed")
        return EngineCoverageUnkeyedContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        claimContainer("single-value")
        return EngineCoverageSingleValueContainer(encoder: self)
    }

    private func claimContainer(_ kind: String) {
        if let claimedContainer {
            recorder.recordFailure(
                EngineCoverageEncodingError.multipleContainers(
                    Self.pathDescription(codingPath), claimedContainer, kind
                )
            )
        } else {
            claimedContainer = kind
        }
    }

    fileprivate func recordKey(owner: String?, key: String) throws {
        guard let owner else {
            throw EngineCoverageEncodingError.unreadableOwner("CodingKeys at \(Self.pathDescription(codingPath))")
        }
        recorder.recordKey(owner: owner, key: key, phase: phase)
    }

    fileprivate func recordString(forKey key: any CodingKey, owner: String?) throws {
        if key.stringValue == "kind" {
            guard let owner else {
                throw EngineCoverageEncodingError.unreadableOwner("CodingKeys at \(Self.pathDescription(codingPath))")
            }
            throw EngineCoverageEncodingError.untypedWireDiscriminator(owner)
        }
        try recordKey(owner: owner, key: key.stringValue)
        try recordEncodedScalar(String.self)
    }

    fileprivate func recordNestedKey(owner: String?, key: String) {
        do {
            try recordKey(owner: owner, key: key)
        } catch {
            recorder.recordFailure(error)
        }
    }

    fileprivate func child(
        appending key: any CodingKey,
        nullableField: EngineNullableField?
    ) -> EngineProtocolCoverageEncoder {
        EngineProtocolCoverageEncoder(
            recorder: recorder,
            phase: phase,
            codingPath: codingPath + [key],
            nullableField: nullableField
        )
    }

    fileprivate func childForArrayElement(_ index: Int) -> EngineProtocolCoverageEncoder {
        child(appending: EngineCoverageIndexKey(index: index), nullableField: nil)
    }

    fileprivate func encodeGeneric<T: Encodable>(_ value: T, nullableField: EngineNullableField?) throws {
        try Self.inspectWireType(T.self, recorder: recorder, phase: phase)

        let optionalValue = value as? any EngineOptionalCoverageValue
        if let optionalType = T.self as? any EngineOptionalCoverageValue.Type,
           let optionalValue, !optionalValue.hasValue {
            try recordTypeObligation(optionalType.wrappedType)
        }
        if let arrayType = T.self as? any EngineArrayCoverageValue.Type,
           let arrayValue = value as? any EngineArrayCoverageValue,
           arrayValue.isEmpty {
            try recordTypeObligation(arrayType.elementType)
        }

        if let nullableType = T.self as? any EngineNullableCoverageValue.Type,
           let nullableValue = value as? any EngineNullableCoverageValue {
            guard let nullableField else {
                throw EngineCoverageEncodingError.nullableWithoutField(String(reflecting: T.self))
            }
            recorder.recordNullable(
                owner: nullableField.owner,
                key: nullableField.key,
                isNull: nullableValue.isNull,
                phase: phase
            )
            if nullableValue.isNull {
                try recordTypeObligation(nullableType.wrappedType)
            }
        }

        if optionalValue?.hasValue != false {
            try recordEncodedType(T.self)
        }

        if phase == .observed, try Self.caseIterableScalarValues(for: T.self) != nil {
            let enumName = try Self.stableTypeName(from: String(reflecting: T.self))
            let enumValue = try Self.scalarJSONToken(from: value)
            recorder.recordEnum(type: enumName, value: enumValue, phase: .observed)
        }

        try value.encode(to: self)
    }

    fileprivate func recordEncodedScalar<T: Encodable>(_ type: T.Type) throws {
        try recordEncodedType(type)
    }

    fileprivate func recordMissingOptional(_ type: any Encodable.Type) throws {
        try Self.inspectWireType(type, recorder: recorder, phase: phase)
        try recordTypeObligation(type)
    }

    private func recordEncodedType(_ type: any Encodable.Type) throws {
        let displayName = try Self.stableTypeName(from: String(reflecting: type))
        recorder.recordEncodedType(type, displayName: displayName, phase: phase)
    }

    private func recordTypeObligation(_ type: any Encodable.Type) throws {
        let displayName = try Self.stableTypeName(from: String(reflecting: type))
        recorder.recordTypeObligation(type, displayName: displayName, phase: phase)
    }

    fileprivate func encodeGeneric<T: Encodable>(
        _ value: T,
        at key: any CodingKey,
        owner: String?
    ) throws {
        try recordKey(owner: owner, key: key.stringValue)
        let field: EngineNullableField?
        if let owner {
            field = EngineNullableField(owner: owner, key: key.stringValue)
        } else {
            field = nil
        }
        let childEncoder = child(appending: key, nullableField: field)
        try childEncoder.encodeGeneric(value, nullableField: field)
    }

    fileprivate func encodeGenericArrayElement<T: Encodable>(_ value: T, index: Int) throws {
        try childForArrayElement(index).encodeGeneric(value, nullableField: nil)
    }

    fileprivate func encodeSingleValueGeneric<T: Encodable>(_ value: T) throws {
        let valueEncoder = EngineProtocolCoverageEncoder(
            recorder: recorder,
            phase: phase,
            codingPath: codingPath,
            nullableField: nullableField
        )
        try valueEncoder.encodeGeneric(value, nullableField: nullableField)
    }

    private static func caseIterableCodingKeys<Key: CodingKey>(_ type: Key.Type) -> [String]? {
        guard let caseIterableType = type as? any CaseIterable.Type else {
            return nil
        }
        var names: [String] = []
        for value in caseIterableType.allCases {
            guard let key = value as? any CodingKey else { return nil }
            names.append(key.stringValue)
        }
        return names
    }

    private static func caseIterableScalarValues(for type: any Encodable.Type) throws -> [String]? {
        guard let caseIterableType = type as? any (Encodable & CaseIterable).Type else {
            return nil
        }
        var values: [String] = []
        for value in caseIterableType.allCases {
            guard let encodableValue = value as? any Encodable else {
                throw EngineCoverageEncodingError.unsupportedEnum(String(reflecting: type), "allCases contains a non-Encodable value")
            }
            values.append(try scalarJSONToken(from: encodableValue))
        }
        guard !values.isEmpty else {
            throw EngineCoverageEncodingError.unsupportedEnum(String(reflecting: type), "empty allCases")
        }
        return values
    }

    private static func inspectWireType(
        _ type: any Encodable.Type,
        recorder: EngineProtocolCoverageRecorder,
        phase: EngineProtocolCoverageRecorder.Phase
    ) throws {
        if type is any RawRepresentable.Type, !(type is any CaseIterable.Type) {
            throw EngineCoverageEncodingError.rawRepresentableNotCaseIterable(
                try stableTypeName(from: String(reflecting: type))
            )
        }

        if let enumValues = try caseIterableScalarValues(for: type), phase == .required {
            let enumName = try stableTypeName(from: String(reflecting: type))
            for enumValue in enumValues {
                recorder.recordEnum(type: enumName, value: enumValue, phase: .required)
            }
        }

        if let optionalType = type as? any EngineOptionalCoverageValue.Type {
            try inspectWireType(optionalType.wrappedType, recorder: recorder, phase: phase)
        }
        if let nullableType = type as? any EngineNullableCoverageValue.Type {
            try inspectWireType(nullableType.wrappedType, recorder: recorder, phase: phase)
        }
        if let arrayType = type as? any EngineArrayCoverageValue.Type {
            try inspectWireType(arrayType.elementType, recorder: recorder, phase: phase)
        }
    }

    private static func scalarJSONToken<T: Encodable>(from value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        if let stringValue = try? JSONDecoder().decode(String.self, from: data) {
            return stringValue
        }
        do {
            let jsonValue = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard jsonValue is NSNumber else {
                throw EngineCoverageEncodingError.unsupportedEnum(
                    String(reflecting: T.self),
                    String(decoding: data, as: UTF8.self)
                )
            }
            let canonicalData = try JSONSerialization.data(withJSONObject: jsonValue, options: [.fragmentsAllowed])
            return String(decoding: canonicalData, as: UTF8.self)
        } catch {
            throw EngineCoverageEncodingError.unsupportedEnum(
                String(reflecting: T.self),
                String(decoding: data, as: UTF8.self)
            )
        }
    }

    private static func stableOwner(from reflected: String) -> String? {
        guard var components = stableTypeComponents(from: reflected), !components.isEmpty else {
            return nil
        }
        guard components.last == "CodingKeys" else {
            return nil
        }
        components.removeLast()
        guard !components.isEmpty else { return nil }
        return components.joined(separator: ".")
    }

    private static func stableTypeName(from reflected: String) throws -> String {
        guard let components = stableTypeComponents(from: reflected), !components.isEmpty else {
            throw EngineCoverageEncodingError.unreadableTypeName(reflected)
        }
        return components.joined(separator: ".")
    }

    private static func stableTypeComponents(from reflected: String) -> [String]? {
        let withoutPrivateContexts = reflected.replacingOccurrences(
            of: #"\(unknown context at [^)]*\)"#,
            with: "",
            options: .regularExpression
        )
        var components = withoutPrivateContexts
            .split(separator: ".", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        components.removeFirst() // String(reflecting:) prefixes the declaring module.
        components.removeAll { $0.contains("unknown context at") }
        return components
    }

    private static func pathDescription(_ path: [any CodingKey]) -> String {
        "$" + path.map { ".\($0.stringValue)" }.joined()
    }
}

private struct EngineCoverageKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: EngineProtocolCoverageEncoder
    let owner: String?
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil(forKey key: Key) throws {
        try encoder.recordKey(owner: owner, key: key.stringValue)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try encoder.encodeGeneric(value, at: key, owner: owner)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(Bool.self) }
    mutating func encode(_ value: String, forKey key: Key) throws { try encoder.recordString(forKey: key, owner: owner) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(Double.self) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(Float.self) }
    mutating func encode(_ value: Int, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(Int.self) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(Int8.self) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(Int16.self) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(Int32.self) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(Int64.self) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(UInt.self) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(UInt8.self) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(UInt16.self) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(UInt32.self) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try encoder.recordKey(owner: owner, key: key.stringValue); try encoder.recordEncodedScalar(UInt64.self) }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encoder.encodeGeneric(value, at: key, owner: owner)
        } else {
            try encoder.recordMissingOptional(T.self)
        }
    }

    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: Bool.self, forKey: key) }
    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws {
        if value != nil {
            try encoder.recordString(forKey: key, owner: owner)
        } else {
            try encoder.recordMissingOptional(String.self)
        }
    }
    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: Double.self, forKey: key) }
    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: Float.self, forKey: key) }
    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: Int.self, forKey: key) }
    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: Int8.self, forKey: key) }
    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: Int16.self, forKey: key) }
    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: Int32.self, forKey: key) }
    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: Int64.self, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: UInt.self, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: UInt8.self, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: UInt16.self, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: UInt32.self, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { try encodeIfPresentScalar(value, type: UInt64.self, forKey: key) }

    private mutating func encodeIfPresentScalar<T: Encodable>(
        _ value: T?, type: T.Type, forKey key: Key
    ) throws {
        if value == nil {
            try encoder.recordMissingOptional(type)
        } else {
            try encoder.recordKey(owner: owner, key: key.stringValue)
            try encoder.recordEncodedScalar(type)
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        encoder.recordNestedKey(owner: owner, key: key.stringValue)
        return encoder.child(appending: key, nullableField: nil).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        encoder.recordNestedKey(owner: owner, key: key.stringValue)
        return encoder.child(appending: key, nullableField: nil).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        encoder.child(appending: EngineCoverageSuperKey(), nullableField: nil)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        encoder.recordNestedKey(owner: owner, key: key.stringValue)
        return encoder.child(appending: key, nullableField: nil)
    }
}

private struct EngineCoverageUnkeyedContainer: UnkeyedEncodingContainer {
    let encoder: EngineProtocolCoverageEncoder
    private(set) var count = 0
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws { count += 1 }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let index = count
        count += 1
        try encoder.encodeGenericArrayElement(value, index: index)
    }

    mutating func encode(_ value: Bool) throws { count += 1; try encoder.recordEncodedScalar(Bool.self) }
    mutating func encode(_ value: String) throws { count += 1; try encoder.recordEncodedScalar(String.self) }
    mutating func encode(_ value: Double) throws { count += 1; try encoder.recordEncodedScalar(Double.self) }
    mutating func encode(_ value: Float) throws { count += 1; try encoder.recordEncodedScalar(Float.self) }
    mutating func encode(_ value: Int) throws { count += 1; try encoder.recordEncodedScalar(Int.self) }
    mutating func encode(_ value: Int8) throws { count += 1; try encoder.recordEncodedScalar(Int8.self) }
    mutating func encode(_ value: Int16) throws { count += 1; try encoder.recordEncodedScalar(Int16.self) }
    mutating func encode(_ value: Int32) throws { count += 1; try encoder.recordEncodedScalar(Int32.self) }
    mutating func encode(_ value: Int64) throws { count += 1; try encoder.recordEncodedScalar(Int64.self) }
    mutating func encode(_ value: UInt) throws { count += 1; try encoder.recordEncodedScalar(UInt.self) }
    mutating func encode(_ value: UInt8) throws { count += 1; try encoder.recordEncodedScalar(UInt8.self) }
    mutating func encode(_ value: UInt16) throws { count += 1; try encoder.recordEncodedScalar(UInt16.self) }
    mutating func encode(_ value: UInt32) throws { count += 1; try encoder.recordEncodedScalar(UInt32.self) }
    mutating func encode(_ value: UInt64) throws { count += 1; try encoder.recordEncodedScalar(UInt64.self) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = encoder.childForArrayElement(count)
        count += 1
        return child.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let child = encoder.childForArrayElement(count)
        count += 1
        return child.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let child = encoder.childForArrayElement(count)
        count += 1
        return child
    }
}

private struct EngineCoverageSingleValueContainer: SingleValueEncodingContainer {
    let encoder: EngineProtocolCoverageEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }

    func encodeNil() throws {}
    func encode(_ value: Bool) throws { try encoder.recordEncodedScalar(Bool.self) }
    func encode(_ value: String) throws { try encoder.recordEncodedScalar(String.self) }
    func encode(_ value: Double) throws { try encoder.recordEncodedScalar(Double.self) }
    func encode(_ value: Float) throws { try encoder.recordEncodedScalar(Float.self) }
    func encode(_ value: Int) throws { try encoder.recordEncodedScalar(Int.self) }
    func encode(_ value: Int8) throws { try encoder.recordEncodedScalar(Int8.self) }
    func encode(_ value: Int16) throws { try encoder.recordEncodedScalar(Int16.self) }
    func encode(_ value: Int32) throws { try encoder.recordEncodedScalar(Int32.self) }
    func encode(_ value: Int64) throws { try encoder.recordEncodedScalar(Int64.self) }
    func encode(_ value: UInt) throws { try encoder.recordEncodedScalar(UInt.self) }
    func encode(_ value: UInt8) throws { try encoder.recordEncodedScalar(UInt8.self) }
    func encode(_ value: UInt16) throws { try encoder.recordEncodedScalar(UInt16.self) }
    func encode(_ value: UInt32) throws { try encoder.recordEncodedScalar(UInt32.self) }
    func encode(_ value: UInt64) throws { try encoder.recordEncodedScalar(UInt64.self) }

    func encode<T: Encodable>(_ value: T) throws {
        try encoder.encodeSingleValueGeneric(value)
    }
}

private struct EngineCoverageIndexKey: CodingKey {
    let intValue: Int?
    let stringValue: String

    init(index: Int) {
        intValue = index
        stringValue = "Index \(index)"
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.intValue = intValue
        stringValue = "Index \(intValue)"
    }
}

private struct EngineCoverageSuperKey: CodingKey {
    let intValue: Int? = nil
    let stringValue = "super"

    init() {}
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { return nil }
}

