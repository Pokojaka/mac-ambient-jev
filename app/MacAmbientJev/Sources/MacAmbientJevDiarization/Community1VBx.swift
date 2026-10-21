import Foundation

// Pinned to FluidAudio 0.15.8, revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc.
// Reference: VBxClustering.swift:168-665.
enum VBxError: Error, CustomStringConvertible {
    case invalidInput(String)
    case numericalFailure(String)

    var description: String {
        switch self {
        case let .invalidInput(reason):
            "invalid VBx input: \(reason)"
        case let .numericalFailure(reason):
            "VBx numerical failure: \(reason)"
        }
    }
}

struct Community1VBxResult {
    let posterior: Community1VBxPosterior
    let pi: [Double]
    let elbos: [Double]

    var iterationCount: Int { elbos.count }
}

struct Community1VBxPosterior {
    let dimension: Int
    fileprivate let sqrtPhi: [Double]
    fileprivate let alpha: [Double]
    fileprivate let phiTerms: [Double]
    fileprivate let logPi: [Double]

    var speakerCount: Int { logPi.count }

    func responsibilities(rho: [Double]) throws -> [Double] {
        guard rho.count == dimension else {
            throw VBxError.invalidInput("rho dimension must match posterior dimension")
        }

        var rhoScaled = [Double](repeating: 0, count: dimension)
        var sumSquares = 0.0
        for coordinate in 0..<dimension {
            let value = rho[coordinate]
            guard value.isFinite else {
                throw VBxError.invalidInput("rho contains a nonfinite value at coordinate \(coordinate)")
            }
            let square = value * value
            guard square.isFinite else {
                throw VBxError.numericalFailure("rho square overflowed at coordinate \(coordinate)")
            }
            sumSquares += square
            guard sumSquares.isFinite else {
                throw VBxError.numericalFailure("rho squared norm overflowed")
            }
            let scaled = value * sqrtPhi[coordinate]
            guard scaled.isFinite else {
                throw VBxError.numericalFailure("scaled rho overflowed at coordinate \(coordinate)")
            }
            rhoScaled[coordinate] = scaled
        }

        let logConstant = Double(dimension) * log(2.0 * Double.pi)
        guard logConstant.isFinite else {
            throw VBxError.numericalFailure("rho log-normalization constant is nonfinite")
        }
        let g = -0.5 * (sumSquares + logConstant)
        guard g.isFinite else {
            throw VBxError.numericalFailure("rho normalization term is nonfinite")
        }

        var scores = [Double](repeating: 0, count: speakerCount)
        for speaker in 0..<speakerCount {
            let offset = speaker * dimension
            var dot = 0.0
            for coordinate in 0..<dimension {
                let product = rhoScaled[coordinate] * alpha[offset + coordinate]
                guard product.isFinite else {
                    throw VBxError.numericalFailure(
                        "rho/alpha product overflowed for speaker \(speaker), coordinate \(coordinate)"
                    )
                }
                dot = dot.addingProduct(rhoScaled[coordinate], alpha[offset + coordinate])
                guard dot.isFinite else {
                    throw VBxError.numericalFailure("rho/alpha dot product is nonfinite for speaker \(speaker)")
                }
            }
            let withPhi = dot + (-0.5 * phiTerms[speaker])
            guard withPhi.isFinite else {
                throw VBxError.numericalFailure("posterior score overflowed for speaker \(speaker)")
            }
            let withG = withPhi + g
            guard withG.isFinite else {
                throw VBxError.numericalFailure("posterior score overflowed for speaker \(speaker)")
            }
            let scaled = Community1Profile.fa * withG
            guard scaled.isFinite else {
                throw VBxError.numericalFailure("posterior score overflowed for speaker \(speaker)")
            }
            let score = scaled + logPi[speaker]
            guard score.isFinite else {
                throw VBxError.numericalFailure("posterior score is nonfinite for speaker \(speaker)")
            }
            scores[speaker] = score
        }
        return try Self.softmax(scores, context: "posterior replay")
    }

    fileprivate static func softmax(_ scores: [Double], context: String) throws -> [Double] {
        guard let maximum = scores.max(), maximum.isFinite else {
            throw VBxError.numericalFailure("\(context) has no finite score")
        }
        var probabilities = [Double](repeating: 0, count: scores.count)
        var sumExp = 0.0
        for index in scores.indices {
            let shifted = scores[index] - maximum
            let value = exp(shifted)
            guard value.isFinite else {
                throw VBxError.numericalFailure("\(context) exponential is nonfinite at speaker \(index)")
            }
            probabilities[index] = value
            sumExp += value
            guard sumExp.isFinite else {
                throw VBxError.numericalFailure("\(context) exponential sum is nonfinite")
            }
        }
        guard sumExp > 0 else {
            throw VBxError.numericalFailure("\(context) exponential sum is not positive")
        }
        let inverseSum = 1.0 / sumExp
        guard inverseSum.isFinite else {
            throw VBxError.numericalFailure("\(context) normalization is nonfinite")
        }
        for index in probabilities.indices {
            probabilities[index] *= inverseSum
            guard probabilities[index].isFinite else {
                throw VBxError.numericalFailure("\(context) probability is nonfinite at speaker \(index)")
            }
        }
        return probabilities
    }
}

enum Community1VBx {
    static func refine(
        rhoFeatures: [[Double]],
        initialClusters: [Int],
        phi: [Double]
    ) throws -> Community1VBxResult {
        try Task.checkCancellation()
        guard !rhoFeatures.isEmpty else {
            throw VBxError.invalidInput("rho features must be nonempty")
        }
        guard let dimension = rhoFeatures.first?.count, dimension > 0 else {
            throw VBxError.invalidInput("rho feature dimension must be positive")
        }
        guard initialClusters.count == rhoFeatures.count else {
            throw VBxError.invalidInput("initial cluster count must match rho feature rows")
        }
        guard phi.count == dimension else {
            throw VBxError.invalidInput("phi dimension must match rho feature dimension")
        }
        for (coordinate, value) in phi.enumerated() where !value.isFinite {
            throw VBxError.invalidInput("phi contains a nonfinite value at coordinate \(coordinate)")
        }
        for (row, features) in rhoFeatures.enumerated() {
            guard features.count == dimension else {
                throw VBxError.invalidInput("rho feature row \(row) has inconsistent dimension")
            }
            for (coordinate, value) in features.enumerated() where !value.isFinite {
                throw VBxError.invalidInput(
                    "rho feature row \(row) contains a nonfinite value at coordinate \(coordinate)"
                )
            }
        }

        var maximumCluster = -1
        for (row, cluster) in initialClusters.enumerated() {
            guard cluster >= 0 else {
                throw VBxError.invalidInput("initial cluster at row \(row) must be nonnegative")
            }
            maximumCluster = max(maximumCluster, cluster)
        }
        guard maximumCluster < Int.max else {
            throw VBxError.invalidInput("initial cluster index cannot be represented as a speaker count")
        }
        let speakerCount = maximumCluster + 1
        guard speakerCount <= initialClusters.count else {
            throw VBxError.invalidInput("initial cluster indices must be contiguous and every cluster must be used")
        }
        var usedClusters = [Bool](repeating: false, count: speakerCount)
        for cluster in initialClusters {
            usedClusters[cluster] = true
        }
        guard usedClusters.allSatisfy({ $0 }) else {
            throw VBxError.invalidInput("initial cluster indices must be contiguous and every cluster must be used")
        }

        let (parameterCount, parameterCountOverflow) = speakerCount.multipliedReportingOverflow(by: dimension)
        guard !parameterCountOverflow else {
            throw VBxError.invalidInput("speaker and feature dimensions exceed supported allocation size")
        }
        let (_, parameterByteCountOverflow) = parameterCount.multipliedReportingOverflow(
            by: MemoryLayout<Double>.stride
        )
        guard !parameterByteCountOverflow else {
            throw VBxError.invalidInput("speaker and feature dimensions exceed supported allocation size")
        }

        let phiClamped = phi.map { max($0, Community1Profile.phiFloor) }
        let sqrtPhi = phiClamped.map { sqrt($0) }
        guard sqrtPhi.allSatisfy({ $0.isFinite }) else {
            throw VBxError.numericalFailure("square root of clamped phi is nonfinite")
        }

        let logConstant = Double(dimension) * log(2.0 * Double.pi)
        guard logConstant.isFinite else {
            throw VBxError.numericalFailure("rho log-normalization constant is nonfinite")
        }
        // Scratch storage is O(N + K*D): row statistics plus speaker parameters, never an N×K posterior.
        var gValues = [Double](repeating: 0, count: rhoFeatures.count)
        for row in rhoFeatures.indices {
            var sumSquares = 0.0
            for coordinate in 0..<dimension {
                let value = rhoFeatures[row][coordinate]
                let square = value * value
                guard square.isFinite else {
                    throw VBxError.numericalFailure("rho square overflowed at row \(row), coordinate \(coordinate)")
                }
                sumSquares += square
                guard sumSquares.isFinite else {
                    throw VBxError.numericalFailure("rho squared norm overflowed at row \(row)")
                }
            }
            let g = -0.5 * (sumSquares + logConstant)
            guard g.isFinite else {
                throw VBxError.numericalFailure("rho normalization term is nonfinite at row \(row)")
            }
            gValues[row] = g
        }

        // Matches FluidAudio's one-hot gamma smoothing softmax and second normalization (VBxClustering.swift:191-235).
        let smoothing = Community1Profile.initializationSmoothing
        var initialProbabilities = [Double](repeating: 0, count: speakerCount)
        var initialCounts = [Double](repeating: 0, count: speakerCount)
        var initialWeightedRho = [Double](repeating: 0, count: parameterCount)
        var scaledRho = [Double](repeating: 0, count: dimension)
        let maximumLogit = smoothing
        for row in rhoFeatures.indices {
            let cluster = initialClusters[row]
            var probabilitySum = 0.0
            for speaker in 0..<speakerCount {
                let logit = speaker == cluster ? smoothing : 0.0
                let probability = exp(logit - maximumLogit)
                guard probability.isFinite else {
                    throw VBxError.numericalFailure("initial smoothing exponential is nonfinite")
                }
                initialProbabilities[speaker] = probability
                probabilitySum += probability
                guard probabilitySum.isFinite else {
                    throw VBxError.numericalFailure("initial smoothing sum is nonfinite")
                }
            }
            guard probabilitySum > 0 else {
                throw VBxError.numericalFailure("initial smoothing sum is not positive")
            }
            let inverseProbabilitySum = 1.0 / probabilitySum
            for speaker in 0..<speakerCount {
                initialProbabilities[speaker] *= inverseProbabilitySum
            }

            // FluidAudio applies a second row normalization after the smoothing softmax.
            var secondSum = 0.0
            for probability in initialProbabilities {
                secondSum += probability
                guard secondSum.isFinite else {
                    throw VBxError.numericalFailure("initial row normalization sum is nonfinite")
                }
            }
            guard secondSum > 0 else {
                throw VBxError.numericalFailure("initial row normalization sum is not positive")
            }
            let inverseSecondSum = 1.0 / secondSum
            for speaker in 0..<speakerCount {
                let probability = initialProbabilities[speaker] * inverseSecondSum
                guard probability.isFinite else {
                    throw VBxError.numericalFailure("initial probability is nonfinite")
                }
                initialProbabilities[speaker] = probability
                initialCounts[speaker] += probability
                guard initialCounts[speaker].isFinite else {
                    throw VBxError.numericalFailure("initial speaker count is nonfinite")
                }
            }

            for coordinate in 0..<dimension {
                let scaled = rhoFeatures[row][coordinate] * sqrtPhi[coordinate]
                guard scaled.isFinite else {
                    throw VBxError.numericalFailure(
                        "scaled rho overflowed at row \(row), coordinate \(coordinate)"
                    )
                }
                scaledRho[coordinate] = scaled
            }
            for speaker in 0..<speakerCount {
                let weight = initialProbabilities[speaker]
                let offset = speaker * dimension
                for coordinate in 0..<dimension {
                    let product = weight * scaledRho[coordinate]
                    guard product.isFinite else {
                        throw VBxError.numericalFailure(
                            "initial weighted rho overflowed for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    let updated = initialWeightedRho[offset + coordinate]
                        .addingProduct(weight, scaledRho[coordinate])
                    guard updated.isFinite else {
                        throw VBxError.numericalFailure(
                            "initial weighted rho sum is nonfinite for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    initialWeightedRho[offset + coordinate] = updated
                }
            }
        }

        let fa = Community1Profile.fa
        let fb = Community1Profile.fb
        let ratio = fa / fb
        guard ratio.isFinite else {
            throw VBxError.numericalFailure("VBx Fa/Fb ratio is nonfinite")
        }
        var pi = [Double](repeating: 1.0 / Double(speakerCount), count: speakerCount)
        var counts = initialCounts
        var weightedRho = initialWeightedRho
        var elbos: [Double] = []
        elbos.reserveCapacity(Community1Profile.maximumIterations)
        var previousElbo = -Double.greatestFiniteMagnitude
        var finalAlpha = [Double](repeating: 0, count: parameterCount)
        var finalPhiTerms = [Double](repeating: 0, count: speakerCount)
        var finalLogPi = [Double](repeating: 0, count: speakerCount)
        var invL = [Double](repeating: 0, count: parameterCount)
        var alpha = [Double](repeating: 0, count: parameterCount)
        var phiTerms = [Double](repeating: 0, count: speakerCount)
        var logPi = [Double](repeating: 0, count: speakerCount)

        for iteration in 0..<Community1Profile.maximumIterations {
            try Task.checkCancellation()

            // Scalar M-step and posterior terms correspond to FluidAudio VBxClustering.swift:331-437.
            for speaker in 0..<speakerCount {
                let countWeight = ratio * counts[speaker]
                guard countWeight.isFinite else {
                    throw VBxError.numericalFailure("inverse-precision count overflowed for speaker \(speaker)")
                }
                let offset = speaker * dimension
                for coordinate in 0..<dimension {
                    let weightedPhi = countWeight * phiClamped[coordinate]
                    guard weightedPhi.isFinite else {
                        throw VBxError.numericalFailure(
                            "inverse-precision product overflowed for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    let denominator = 1.0 + weightedPhi
                    guard denominator.isFinite else {
                        throw VBxError.numericalFailure(
                            "inverse-precision denominator is nonfinite for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    let inverse = 1.0 / max(denominator, Community1Profile.inversePrecisionDenominatorFloor)
                    guard inverse.isFinite else {
                        throw VBxError.numericalFailure(
                            "inverse precision is nonfinite for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    invL[offset + coordinate] = inverse
                    let scaledWeightedRho = weightedRho[offset + coordinate] * inverse
                    guard scaledWeightedRho.isFinite else {
                        throw VBxError.numericalFailure(
                            "alpha intermediate is nonfinite for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    let parameter = scaledWeightedRho * ratio
                    guard parameter.isFinite else {
                        throw VBxError.numericalFailure(
                            "alpha is nonfinite for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    alpha[offset + coordinate] = parameter
                }
            }

            for speaker in 0..<speakerCount {
                let offset = speaker * dimension
                var sum = 0.0
                for coordinate in 0..<dimension {
                    let parameter = alpha[offset + coordinate]
                    let square = parameter * parameter
                    guard square.isFinite else {
                        throw VBxError.numericalFailure(
                            "alpha square overflowed for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    let varianceTerm = square + invL[offset + coordinate]
                    guard varianceTerm.isFinite else {
                        throw VBxError.numericalFailure(
                            "phi term overflowed for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    let weightedTerm = varianceTerm * phiClamped[coordinate]
                    guard weightedTerm.isFinite else {
                        throw VBxError.numericalFailure(
                            "phi term overflowed for speaker \(speaker), coordinate \(coordinate)"
                        )
                    }
                    sum += weightedTerm
                    guard sum.isFinite else {
                        throw VBxError.numericalFailure("phi term sum is nonfinite for speaker \(speaker)")
                    }
                }
                phiTerms[speaker] = sum
                let prior = max(pi[speaker], Community1Profile.logPriorFloor)
                logPi[speaker] = log(prior)
                guard logPi[speaker].isFinite else {
                    throw VBxError.numericalFailure("log prior is nonfinite for speaker \(speaker)")
                }
            }

            var nextCounts = [Double](repeating: 0, count: speakerCount)
            var nextWeightedRho = [Double](repeating: 0, count: parameterCount)
            var logLikelihood = 0.0
            var scores = [Double](repeating: 0, count: speakerCount)
            var probabilities = [Double](repeating: 0, count: speakerCount)

            // Stream FluidAudio's logP/gamma E-step one row at a time (VBxClustering.swift:439-573).
            for row in rhoFeatures.indices {
                for coordinate in 0..<dimension {
                    let scaled = rhoFeatures[row][coordinate] * sqrtPhi[coordinate]
                    guard scaled.isFinite else {
                        throw VBxError.numericalFailure(
                            "scaled rho overflowed at row \(row), coordinate \(coordinate)"
                        )
                    }
                    scaledRho[coordinate] = scaled
                }

                for speaker in 0..<speakerCount {
                    let offset = speaker * dimension
                    var dot = 0.0
                    for coordinate in 0..<dimension {
                        let product = scaledRho[coordinate] * alpha[offset + coordinate]
                        guard product.isFinite else {
                            throw VBxError.numericalFailure(
                                "rho/alpha product overflowed at row \(row), speaker \(speaker), coordinate \(coordinate)"
                            )
                        }
                        dot = dot.addingProduct(scaledRho[coordinate], alpha[offset + coordinate])
                        guard dot.isFinite else {
                            throw VBxError.numericalFailure(
                                "rho/alpha dot product is nonfinite at row \(row), speaker \(speaker)"
                            )
                        }
                    }
                    let withPhi = dot + (-0.5 * phiTerms[speaker])
                    guard withPhi.isFinite else {
                        throw VBxError.numericalFailure("score is nonfinite at row \(row), speaker \(speaker)")
                    }
                    let withG = withPhi + gValues[row]
                    guard withG.isFinite else {
                        throw VBxError.numericalFailure("score is nonfinite at row \(row), speaker \(speaker)")
                    }
                    let scaledScore = fa * withG
                    guard scaledScore.isFinite else {
                        throw VBxError.numericalFailure("score is nonfinite at row \(row), speaker \(speaker)")
                    }
                    let score = scaledScore + logPi[speaker]
                    guard score.isFinite else {
                        throw VBxError.numericalFailure("score is nonfinite at row \(row), speaker \(speaker)")
                    }
                    scores[speaker] = score
                }

                guard let rowMaximum = scores.max(), rowMaximum.isFinite else {
                    throw VBxError.numericalFailure("E-step row \(row) has no finite score")
                }
                var sumExp = 0.0
                for speaker in 0..<speakerCount {
                    let exponential = exp(scores[speaker] - rowMaximum)
                    guard exponential.isFinite else {
                        throw VBxError.numericalFailure("E-step exponential is nonfinite at row \(row)")
                    }
                    probabilities[speaker] = exponential
                    sumExp += exponential
                    guard sumExp.isFinite else {
                        throw VBxError.numericalFailure("E-step exponential sum is nonfinite at row \(row)")
                    }
                }
                guard sumExp > 0 else {
                    throw VBxError.numericalFailure("E-step exponential sum is not positive at row \(row)")
                }
                let inverseSum = 1.0 / sumExp
                guard inverseSum.isFinite else {
                    throw VBxError.numericalFailure("E-step normalization is nonfinite at row \(row)")
                }
                for speaker in 0..<speakerCount {
                    let probability = probabilities[speaker] * inverseSum
                    guard probability.isFinite else {
                        throw VBxError.numericalFailure("E-step probability is nonfinite at row \(row)")
                    }
                    probabilities[speaker] = probability
                    nextCounts[speaker] += probability
                    guard nextCounts[speaker].isFinite else {
                        throw VBxError.numericalFailure("E-step count overflowed for speaker \(speaker)")
                    }
                    let offset = speaker * dimension
                    for coordinate in 0..<dimension {
                        let product = probability * scaledRho[coordinate]
                        guard product.isFinite else {
                            throw VBxError.numericalFailure(
                                "E-step weighted rho overflowed for speaker \(speaker), coordinate \(coordinate)"
                            )
                        }
                        let updated = nextWeightedRho[offset + coordinate]
                            .addingProduct(probability, scaledRho[coordinate])
                        guard updated.isFinite else {
                            throw VBxError.numericalFailure(
                                "E-step weighted rho sum is nonfinite for speaker \(speaker), coordinate \(coordinate)"
                            )
                        }
                        nextWeightedRho[offset + coordinate] = updated
                    }
                }
                let likelihoodTerm = rowMaximum + log(sumExp)
                guard likelihoodTerm.isFinite else {
                    throw VBxError.numericalFailure("E-step likelihood is nonfinite at row \(row)")
                }
                logLikelihood += likelihoodTerm
                guard logLikelihood.isFinite else {
                    throw VBxError.numericalFailure("E-step log likelihood is nonfinite")
                }
            }

            var piSum = 0.0
            for count in nextCounts {
                piSum += count
                guard piSum.isFinite else {
                    throw VBxError.numericalFailure("updated prior sum is nonfinite")
                }
            }
            guard piSum > 0 else {
                throw VBxError.numericalFailure("updated prior sum is not positive")
            }
            let inversePiSum = 1.0 / piSum
            guard inversePiSum.isFinite else {
                throw VBxError.numericalFailure("updated prior normalization is nonfinite")
            }
            var nextPi = [Double](repeating: 0, count: speakerCount)
            for speaker in 0..<speakerCount {
                nextPi[speaker] = nextCounts[speaker] * inversePiSum
                guard nextPi[speaker].isFinite else {
                    throw VBxError.numericalFailure("updated prior is nonfinite for speaker \(speaker)")
                }
            }

            // Scalar ELBO regularizer follows FluidAudio VBxClustering.swift:624-648.
            var sumLogInv = 0.0
            var sumInv = 0.0
            var sumAlphaSq = 0.0
            for index in 0..<parameterCount {
                let logInverse = log(invL[index])
                guard logInverse.isFinite else {
                    throw VBxError.numericalFailure("log inverse precision is nonfinite at index \(index)")
                }
                sumLogInv += logInverse
                sumInv += invL[index]
                let square = alpha[index] * alpha[index]
                guard square.isFinite else {
                    throw VBxError.numericalFailure("alpha square overflowed at index \(index)")
                }
                sumAlphaSq += square
                guard sumLogInv.isFinite, sumInv.isFinite, sumAlphaSq.isFinite else {
                    throw VBxError.numericalFailure("VBx ELBO regularizer sum is nonfinite")
                }
            }
            let regularizer = sumLogInv - sumInv - sumAlphaSq + Double(parameterCount)
            guard regularizer.isFinite else {
                throw VBxError.numericalFailure("VBx ELBO regularizer is nonfinite")
            }
            let scaledRegularizer = fb * 0.5 * regularizer
            guard scaledRegularizer.isFinite else {
                throw VBxError.numericalFailure("VBx ELBO regularizer is nonfinite")
            }
            let elbo = logLikelihood + scaledRegularizer
            guard elbo.isFinite else {
                throw VBxError.numericalFailure("VBx ELBO is nonfinite")
            }
            elbos.append(elbo)

            // Replay snapshots the E-step input prior; returned pi below is the post-M-step prior.
            finalAlpha = alpha
            finalPhiTerms = phiTerms
            finalLogPi = logPi

            let converged: Bool
            if iteration > 0 {
                let improvement = elbo - previousElbo
                guard improvement.isFinite else {
                    throw VBxError.numericalFailure("VBx ELBO improvement is nonfinite")
                }
                converged = abs(improvement) < Community1Profile.elboTolerance
            } else {
                converged = false
            }
            previousElbo = elbo
            pi = nextPi
            counts = nextCounts
            weightedRho = nextWeightedRho
            if converged {
                break
            }
        }

        let posterior = Community1VBxPosterior(
            dimension: dimension,
            sqrtPhi: sqrtPhi,
            alpha: finalAlpha,
            phiTerms: finalPhiTerms,
            logPi: finalLogPi
        )
        return Community1VBxResult(posterior: posterior, pi: pi, elbos: elbos)
    }
}
