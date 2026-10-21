#if os(macOS)
import CoreML
import CryptoKit
import Foundation
import Testing
@testable import FluidAudio

private enum DiarizationPLDAParityError: Error, CustomStringConvertible {
    case invalidModelDirectory(String)
    case invalidAsset(String)
    case invalidGraph(String)

    var description: String {
        switch self {
        case .invalidModelDirectory(let reason):
            return "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY: \(reason)"
        case .invalidAsset(let reason):
            return "Invalid PLDA parity asset: \(reason)"
        case .invalidGraph(let reason):
            return "Invalid PldaRho.mlmodelc graph: \(reason)"
        }
    }
}

private struct DiarizationPLDAParityCase {
    let name: String
    let construction: String
    let embeddings: [[Float]]
}

extension DiarizationParityFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func pldaRhoMatchesCoreML() async throws {
        let modelDirectory = try pldaModelDirectory()
        let pldaJSONURL = modelDirectory.appendingPathComponent("plda-parameters.json", isDirectory: false)
        let xvectorJSONURL = modelDirectory.appendingPathComponent("xvector-transform.json", isDirectory: false)
        let modelURL = modelDirectory.appendingPathComponent("PldaRho.mlmodelc", isDirectory: true)
        let weightURL = modelURL.appendingPathComponent("weights/weight.bin", isDirectory: false)
        let modelMILURL = modelURL.appendingPathComponent("model.mil", isDirectory: false)

        let pldaJSON = try Data(contentsOf: pldaJSONURL)
        let xvectorJSON = try Data(contentsOf: xvectorJSONURL)
        let pldaSHA256 = sha256Hex(pldaJSON)
        let xvectorSHA256 = sha256Hex(xvectorJSON)
        try #require(
            pldaSHA256 == "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f",
            "plda-parameters.json SHA-256 must match the pinned FluidInference asset; found \(pldaSHA256)"
        )
        try #require(
            xvectorSHA256 == "f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688",
            "xvector-transform.json SHA-256 must match the pinned FluidInference asset; found \(xvectorSHA256)"
        )

        let pldaAssets = try parsePLDAAssets(pldaJSON)
        let xvectorAssets = try parseXVectorAssets(xvectorJSON)
        let modelMIL = try String(contentsOf: modelMILURL, encoding: .utf8)
        try validatePLDAGraphDeclarations(modelMIL)
        let weightData = try Data(contentsOf: weightURL)
        let modelWeightsSHA256 = sha256Hex(weightData)

        let referenceSqrtSpectrum = try blobFloat32(
            weightData,
            blobOffset: 64,
            count: 128,
            name: "sqrt_phi"
        )
        let referenceProjection = try blobFloat32(
            weightData,
            blobOffset: 640,
            count: 128 * 128,
            name: "transform_plda_tr"
        )
        let graphMu = try blobFloat32(weightData, blobOffset: 66240, count: 128, name: "transform_mu")
        let graphMean2 = try blobFloat32(weightData, blobOffset: 66816, count: 128, name: "transform_mean2")
        let graphMean1 = try blobFloat32(weightData, blobOffset: 67392, count: 256, name: "transform_mean1")
        let graphLDA = try blobFloat32(weightData, blobOffset: 68480, count: 128 * 256, name: "transpose_0")

        try #require(sameFloat32Bits(graphMu, pldaAssets.mean), "Embedded PLDA mean differs from plda-parameters.json mu")
        try #require(sameFloat32Bits(graphMean1, xvectorAssets.mean1), "Embedded transform_mean1 differs from xvector-transform.json mean1")
        try #require(sameFloat32Bits(graphMean2, xvectorAssets.mean2), "Embedded transform_mean2 differs from xvector-transform.json mean2")
        try #require(
            graphLDA == transposedLDA(xvectorAssets.lda),
            "Embedded transpose_0 differs from the transpose of xvector-transform.json lda"
        )
        try #require(pldaAssets.psi.allSatisfy { $0.isFinite && $0 >= 0 }, "PLDA psi must be finite and nonnegative")

        let coordinateSigns = try projectionCoordinateSigns(referenceProjection)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let transform = PLDATransform(pldaRhoModel: model, psi: pldaAssets.psi.map(Double.init))
        try #require(
            transform.phiParameters == pldaAssets.psi.map(Double.init),
            "PLDATransform must receive raw JSON psi widened to Double"
        )

        let cases = makePLDAParityCases(mean1: graphMean1)
        try #require(
            cases.map(\.name) == ["normalized-vectors", "first-norm-floor", "edge-vectors"],
            "PLDA parity case order and names must remain fixed"
        )
        var serializedCases: [[String: Any]] = []
        serializedCases.reserveCapacity(cases.count)
        for parityCase in cases {
            try #require(!parityCase.embeddings.isEmpty, "\(parityCase.name): embeddings must not be empty")
            try #require(
                parityCase.embeddings.allSatisfy { $0.count == 256 && $0.allSatisfy(\.isFinite) },
                "\(parityCase.name): embeddings must be finite Float32 vectors of dimension 256"
            )
            let expectedRho = try await transform.transform(parityCase.embeddings)
            try #require(
                expectedRho.count == parityCase.embeddings.count
                    && expectedRho.allSatisfy { $0.count == 128 && $0.allSatisfy(\.isFinite) },
                "\(parityCase.name): Core ML rho output must be finite with shape [N, 128]"
            )
            serializedCases.append([
                "name": parityCase.name,
                "construction": parityCase.construction,
                "embeddings": try DiarizationParityOracle.tensor(
                    parityCase.embeddings.flatMap { $0 },
                    shape: [parityCase.embeddings.count, 256]
                ),
                "expectedRho": try DiarizationParityOracle.tensor(
                    expectedRho.flatMap { $0 },
                    shape: [expectedRho.count, 128]
                ),
            ])
        }

        let fixture: [String: Any] = [
            "metadata": DiarizationParityOracle.metadata(
                inputConstruction: "The oracle loads only the caller-provided PldaRho.mlmodelc using MLModel(contentsOf:configuration:) with .cpuOnly, then runs the pinned FluidAudio 0.15.8 PLDATransform.transform. The input assets are plda-parameters.json and xvector-transform.json from FluidInference revision df2625ac79a7ac6b65ad868fee6d80f320da4232; their SHA-256 values are recorded at the top level. Every stored embedding is the exact Float32 value passed to FluidAudio. normalized-vectors has six deterministic sin/cos plus small-jitter rows normalized after Float32 rounding. first-norm-floor starts from the graph's exact Float32 mean1 and includes it unchanged, coordinate-0 perturbations of both signs at 0.5e-6, 1e-6, and 2e-6, and one all-coordinate 0.5e-6/16 perturbation (all values Float32-rounded). edge-vectors contains zero and positive/negative coordinate unit vectors for axes 0, 1, 63, 127, 128, and 255. Reference projection and sqrt spectrum are decoded from the Core ML BLOBFILE records after their 64-byte headers; graph declarations, shapes, offsets, and JSON parameter correspondence are checked. No alternate or portable inference implementation is used as the oracle.",
                comparisonRule: "psi is the JSON float32 tensor widened to float64 without transformation; referenceProjection and referenceSqrtSpectrum are exact float32 tensors read from the model's weights. coordinateSigns is sign(row[argmax(abs(row))]) for each reference projection row, scanning left-to-right and replacing a maximum only on strict greater-than so ties retain the lowest coordinate. rho is stored as float64 values widened from the model's float32 output. Portable comparison uses signed per-coordinate absolute error <= 1e-4 with the stored coordinate orientation; sign-invariant comparison is not accepted. The cases exercise the first normalization floor only; they do not claim to exercise the second normalization floor."
            ),
            "modelRevision": "df2625ac79a7ac6b65ad868fee6d80f320da4232",
            "pldaSHA256": pldaSHA256,
            "xvectorSHA256": xvectorSHA256,
            "modelWeightsSHA256": modelWeightsSHA256,
            "coordinateSigns": coordinateSigns,
            "psi": try DiarizationParityOracle.tensor(pldaAssets.psi.map(Double.init), shape: [128]),
            "referenceProjection": try DiarizationParityOracle.tensor(referenceProjection, shape: [128, 128]),
            "referenceSqrtSpectrum": try DiarizationParityOracle.tensor(referenceSqrtSpectrum, shape: [128]),
            "cases": serializedCases,
        ]
        try DiarizationParityOracle.checkPLDARhoOrWrite(fixture)
    }
}

private func pldaModelDirectory() throws -> URL {
    let environmentName = "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY"
    guard let directoryPath = ProcessInfo.processInfo.environment[environmentName] else {
        throw DiarizationPLDAParityError.invalidModelDirectory("is required and must name an absolute existing directory")
    }
    guard !directoryPath.isEmpty else {
        throw DiarizationPLDAParityError.invalidModelDirectory("must not be empty")
    }
    guard directoryPath.hasPrefix("/") else {
        throw DiarizationPLDAParityError.invalidModelDirectory("must be an absolute path; found \(directoryPath)")
    }
    let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw DiarizationPLDAParityError.invalidModelDirectory("does not exist or is not a directory: \(directoryPath)")
    }
    return directoryURL
}

private struct PLDAJSONAssets {
    let mean: [Float]
    let transform: [Float]
    let psi: [Float]
}

private struct XVectorJSONAssets {
    let mean1: [Float]
    let mean2: [Float]
    let lda: [Float]
}

private func parsePLDAAssets(_ data: Data) throws -> PLDAJSONAssets {
    let root = try jsonDictionary(data, named: "plda-parameters.json")
    guard let tensors = root["tensors"] as? [String: Any] else {
        throw DiarizationPLDAParityError.invalidAsset("plda-parameters.json must contain a named tensors object")
    }
    return PLDAJSONAssets(
        mean: try jsonFloat32Tensor(tensors["mu"], name: "plda-parameters.json mu", shape: [128]),
        transform: try jsonFloat32Tensor(tensors["tr"], name: "plda-parameters.json tr", shape: [128, 128]),
        psi: try jsonFloat32Tensor(tensors["psi"], name: "plda-parameters.json psi", shape: [128])
    )
}

private func parseXVectorAssets(_ data: Data) throws -> XVectorJSONAssets {
    let root = try jsonDictionary(data, named: "xvector-transform.json")
    guard let tensors = root["tensors"] as? [String: Any] else {
        throw DiarizationPLDAParityError.invalidAsset("xvector-transform.json must contain a named tensors object")
    }
    return XVectorJSONAssets(
        mean1: try jsonFloat32Tensor(tensors["mean1"], name: "xvector-transform.json mean1", shape: [256]),
        mean2: try jsonFloat32Tensor(tensors["mean2"], name: "xvector-transform.json mean2", shape: [128]),
        lda: try jsonFloat32Tensor(tensors["lda"], name: "xvector-transform.json lda", shape: [256, 128])
    )
}

private func jsonDictionary(_ data: Data, named name: String) throws -> [String: Any] {
    guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw DiarizationPLDAParityError.invalidAsset("\(name) must be a JSON object")
    }
    return dictionary
}

private func jsonFloat32Tensor(_ value: Any?, name: String, shape expectedShape: [Int]) throws -> [Float] {
    guard
        let tensor = value as? [String: Any],
        let dtype = tensor["dtype"] as? String,
        let layout = tensor["layout"] as? String,
        let shape = tensor["shape"] as? [Int],
        let encoded = tensor["data_base64"] as? String
    else {
        throw DiarizationPLDAParityError.invalidAsset("\(name) must have dtype, layout, shape, and data_base64 fields")
    }
    guard dtype == "float32", layout == "row-major", shape == expectedShape else {
        throw DiarizationPLDAParityError.invalidAsset(
            "\(name) must be float32 row-major with shape \(expectedShape); got dtype=\(dtype), layout=\(layout), shape=\(shape)"
        )
    }
    guard let payload = Data(base64Encoded: encoded), payload.count == expectedShape.reduce(1, *) * MemoryLayout<UInt32>.size else {
        throw DiarizationPLDAParityError.invalidAsset("\(name) has invalid base64 data or byte count")
    }
    let values = payload.withUnsafeBytes { rawBuffer in
        (0..<(payload.count / MemoryLayout<UInt32>.size)).map { index in
            let bits = rawBuffer.loadUnaligned(fromByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self)
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
    }
    guard values.allSatisfy(\.isFinite) else {
        throw DiarizationPLDAParityError.invalidAsset("\(name) contains a non-finite float32 value")
    }
    return values
}

private func validatePLDAGraphDeclarations(_ modelMIL: String) throws {
    let declarations = [
        ("sqrt_phi", "[128]", 64),
        ("transform_plda_tr", "[128,128]", 640),
        ("transform_mu", "[128]", 66240),
        ("transform_mean2", "[128]", 66816),
        ("transform_mean1", "[256]", 67392),
        ("transpose_0", "[128,256]", 68480),
    ]
    let normalizedLines = modelMIL.split(whereSeparator: \.isNewline).map {
        $0.filter { !$0.isWhitespace }
    }
    for (name, shape, offset) in declarations {
        let expectedName = "name=tensor<string,[]>(\"\(name)\")"
        let expectedShape = "tensor<fp32,\(shape)>"
        let expectedBlob = "BLOBFILE(path=tensor<string,[]>(\"@model_path/weights/weight.bin\"),offset=tensor<uint64,[]>(\(offset)))"
        let matches = normalizedLines.filter {
            $0.contains(expectedName) && $0.contains(expectedShape) && $0.contains(expectedBlob)
        }
        guard matches.count == 1 else {
            throw DiarizationPLDAParityError.invalidGraph(
                "expected exactly one Float32 \(shape) BLOBFILE declaration for \(name) at offset \(offset); found \(matches.count)"
            )
        }
    }
}

private func blobFloat32(_ data: Data, blobOffset: Int, count: Int, name: String) throws -> [Float] {
    let (payloadOffset, offsetOverflow) = blobOffset.addingReportingOverflow(64)
    let (payloadBytes, sizeOverflow) = count.multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
    let (payloadEnd, endOverflow) = payloadOffset.addingReportingOverflow(payloadBytes)
    guard !offsetOverflow, !sizeOverflow, !endOverflow, payloadOffset >= 0, payloadEnd <= data.count else {
        throw DiarizationPLDAParityError.invalidGraph(
            "\(name) Float32 BLOBFILE at offset \(blobOffset) plus its 64-byte header and \(count) values exceeds weight.bin"
        )
    }
    let values = data.withUnsafeBytes { rawBuffer in
        (0..<count).map { index in
            let bits = rawBuffer.loadUnaligned(
                fromByteOffset: payloadOffset + index * MemoryLayout<UInt32>.size,
                as: UInt32.self
            )
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
    }
    guard values.allSatisfy(\.isFinite) else {
        throw DiarizationPLDAParityError.invalidGraph("\(name) BLOBFILE contains a non-finite Float32 value")
    }
    return values
}

private func transposedLDA(_ values: [Float]) -> [Float] {
    (0..<128).flatMap { row in
        (0..<256).map { column in values[column * 128 + row] }
    }
}

private func sameFloat32Bits(_ lhs: [Float], _ rhs: [Float]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.bitPattern == $1.bitPattern }
}

private func projectionCoordinateSigns(_ projection: [Float]) throws -> [Int] {
    try #require(projection.count == 128 * 128, "Reference PLDA projection must have shape [128, 128]")
    return (0..<128).map { row in
        let start = row * 128
        var maximumMagnitude: Float = 0
        var maximumCoordinate = 0
        for coordinate in 0..<128 {
            let magnitude = abs(projection[start + coordinate])
            if magnitude > maximumMagnitude {
                maximumMagnitude = magnitude
                maximumCoordinate = coordinate
            }
        }
        return projection[start + maximumCoordinate] < 0 ? -1 : 1
    }
}

private func makePLDAParityCases(mean1: [Float]) -> [DiarizationPLDAParityCase] {
    let normalized = (0..<6).map { row in
        let rounded = (0..<256).map { coordinate in
            Float(
                sin(Double((row + 1) * (coordinate + 1)) * 0.037)
                    + cos(Double((row + 3) * (coordinate + 2)) * 0.019) * 0.31
                    + Double((row * 17 + coordinate * 3) % 7 - 3) * 0.001
            )
        }
        let norm = rounded.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        return rounded.map { Float(Double($0) / norm) }
    }

    var floorEmbeddings = [mean1]
    for perturbation in [0.5e-6, 1e-6, 2e-6] {
        for sign in [-1.0, 1.0] {
            var embedding = mean1
            embedding[0] = mean1[0] + Float(sign * perturbation)
            floorEmbeddings.append(embedding)
        }
    }
    let allCoordinatePerturbation = Float(0.5e-6 / 16.0)
    floorEmbeddings.append(mean1.map { $0 + allCoordinatePerturbation })

    let unitAxes = [0, 1, 63, 127, 128, 255]
    var edgeEmbeddings = [Array(repeating: Float.zero, count: 256)]
    for axis in unitAxes {
        var positive = Array(repeating: Float.zero, count: 256)
        positive[axis] = 1
        edgeEmbeddings.append(positive)
        var negative = Array(repeating: Float.zero, count: 256)
        negative[axis] = -1
        edgeEmbeddings.append(negative)
    }

    return [
        DiarizationPLDAParityCase(
            name: "normalized-vectors",
            construction: "Six deterministic 256-dimensional vectors. raw[row,d]=Float32(sin(Double((row+1)*(d+1))*0.037)+0.31*cos(Double((row+3)*(d+2))*0.019)+Double((row*17+d*3)%7-3)*0.001); compute the norm from the widened Float32 raw coordinates in Double, divide in Double, and round every normalized coordinate to Float32.",
            embeddings: normalized
        ),
        DiarizationPLDAParityCase(
            name: "first-norm-floor",
            construction: "Eight 256-dimensional inputs based on the exact graph Float32 mean1: unchanged mean1; coordinate 0 changed by both signs of 0.5e-6, 1e-6, and 2e-6 using Float32 addition; and all 256 coordinates changed by Float32(0.5e-6/16) using Float32 addition. Stored values are the exact Float32 inputs after rounding.",
            embeddings: floorEmbeddings
        ),
        DiarizationPLDAParityCase(
            name: "edge-vectors",
            construction: "One all-zero 256-dimensional input followed by positive and negative coordinate unit vectors on axes 0, 1, 63, 127, 128, and 255. These inputs are exact Float32 values.",
            embeddings: edgeEmbeddings
        ),
    ]
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
#endif
