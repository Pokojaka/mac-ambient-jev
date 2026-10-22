// Adapted from swift-transformers 1.3.4 Sources/Tokenizers/UnigramTokenizer.swift,
// TokenLattice.swift, and Trie.swift:
// https://raw.githubusercontent.com/huggingface/swift-transformers/1.3.4/Sources/Tokenizers/UnigramTokenizer.swift
// https://raw.githubusercontent.com/huggingface/swift-transformers/1.3.4/Sources/Tokenizers/TokenLattice.swift
// https://raw.githubusercontent.com/huggingface/swift-transformers/1.3.4/Sources/Tokenizers/Trie.swift
// Copyright © 2024 Hugging Face. All rights reserved. Portions authored by Pedro Cuenca.
// Licensed under the Apache License, Version 2.0:
// https://www.apache.org/licenses/LICENSE-2.0
// Upstream license: https://github.com/huggingface/swift-transformers/blob/1.3.4/LICENSE

struct ClauseTaggerUnigram: Sendable {
    private struct TrieNode: Sendable {
        var children: [UInt32: Int] = [:]
        var tokenID: Int?
    }

    private struct LatticeNode {
        let tokenID: Int
        let startOffset: Int
        let length: Int
        let score: Float
        let backtraceScore: Float
        let previousIndex: Int?
    }

    // This is a value-only trie built during initialization and never mutated afterward.
    private let trieNodes: [TrieNode]
    private let vocabularyScores: [Float]
    private let unknownID: Int
    private let unknownScore: Float

    init(configuration: ClauseTaggerTokenizerConfiguration) {
        var nodes = [TrieNode()]
        for (tokenID, entry) in configuration.vocabulary.enumerated() {
            var nodeIndex = 0
            for scalar in entry.token.unicodeScalars {
                let edge = scalar.value
                if let childIndex = nodes[nodeIndex].children[edge] {
                    nodeIndex = childIndex
                } else {
                    let childIndex = nodes.count
                    nodes.append(TrieNode())
                    nodes[nodeIndex].children[edge] = childIndex
                    nodeIndex = childIndex
                }
            }
            nodes[nodeIndex].tokenID = tokenID
        }

        trieNodes = nodes
        vocabularyScores = configuration.vocabulary.map(\.score)
        unknownID = configuration.unknownID
        unknownScore = configuration.vocabulary.reduce(Float(999)) { min($0, $1.score) } - 10
    }

    func tokenize(_ text: String) throws -> [String] {
        let scalars = Array(text.unicodeScalars)
        let scalarCount = scalars.count
        guard scalarCount > 0 else { return [] }

        var latticeNodes: [LatticeNode] = []
        latticeNodes.reserveCapacity(scalarCount)
        var endingNodes = Array(repeating: [Int](), count: scalarCount + 1)

        // BOS is the first (and initially only) predecessor at scalar offset zero.
        let bosIndex = latticeNodes.count
        latticeNodes.append(LatticeNode(
            tokenID: unknownID,
            startOffset: 0,
            length: 0,
            score: 0,
            backtraceScore: 0,
            previousIndex: nil
        ))
        endingNodes[0].append(bosIndex)

        func insertNode(startOffset: Int, length: Int, tokenID: Int, score: Float) throws {
            let endOffset = startOffset + length
            var bestPreviousIndex: Int?
            var bestScore: Float = 0

            for previousIndex in endingNodes[startOffset] {
                let previousNode = latticeNodes[previousIndex]
                // Match upstream Float arithmetic: add each candidate before comparing.
                // Comparing predecessor scores first can change choices through Float rounding.
                let candidateScore = Float(previousNode.backtraceScore + score)
                guard candidateScore.isFinite else {
                    throw ClauseTaggerTokenizerError.unrepresentableText
                }
                // Predecessors are visited in lattice insertion order; strict comparison
                // preserves the first predecessor when scores tie.
                if bestPreviousIndex == nil || candidateScore > bestScore {
                    bestPreviousIndex = previousIndex
                    bestScore = candidateScore
                }
            }

            guard let bestPreviousIndex else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            let nodeIndex = latticeNodes.count
            latticeNodes.append(LatticeNode(
                tokenID: tokenID,
                startOffset: startOffset,
                length: length,
                score: score,
                backtraceScore: bestScore,
                previousIndex: bestPreviousIndex
            ))
            endingNodes[endOffset].append(nodeIndex)
        }

        for startOffset in 0..<scalarCount {
            var trieIndex = 0
            var prefixLength = 0
            var hasSingleScalarMatch = false

            // A trie walk reports terminal prefixes shortest-to-longest. Inserting in
            // this order reproduces the upstream lattice's node and ending-node order.
            while startOffset + prefixLength < scalarCount {
                let edge = scalars[startOffset + prefixLength].value
                guard let childIndex = trieNodes[trieIndex].children[edge] else { break }
                trieIndex = childIndex
                prefixLength += 1

                if let tokenID = trieNodes[trieIndex].tokenID {
                    try insertNode(
                        startOffset: startOffset,
                        length: prefixLength,
                        tokenID: tokenID,
                        score: vocabularyScores[tokenID]
                    )
                    if prefixLength == 1 {
                        hasSingleScalarMatch = true
                    }
                }
            }

            if !hasSingleScalarMatch {
                // Byte fallback is handled by the wrapper; this node represents the
                // actual input scalar while retaining the model's unknown-token score.
                try insertNode(
                    startOffset: startOffset,
                    length: 1,
                    tokenID: unknownID,
                    score: unknownScore
                )
            }
        }

        var eosPreviousIndex: Int?
        var eosScore: Float = 0
        for previousIndex in endingNodes[scalarCount] {
            let previousNode = latticeNodes[previousIndex]
            let candidateScore = Float(previousNode.backtraceScore + 0)
            guard candidateScore.isFinite else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            if eosPreviousIndex == nil || candidateScore > eosScore {
                eosPreviousIndex = previousIndex
                eosScore = candidateScore
            }
        }

        guard var currentIndex = eosPreviousIndex else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }

        var reversedTokens: [String] = []
        reversedTokens.reserveCapacity(scalarCount)
        var reconstructedScalarCount = 0
        while currentIndex != bosIndex {
            guard latticeNodes.indices.contains(currentIndex) else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            let node = latticeNodes[currentIndex]
            guard node.length > 0,
                  node.startOffset >= 0,
                  node.startOffset <= scalarCount - node.length,
                  reconstructedScalarCount < scalarCount,
                  let previousIndex = node.previousIndex,
                  latticeNodes.indices.contains(previousIndex)
            else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            let previousNode = latticeNodes[previousIndex]
            guard previousNode.startOffset + previousNode.length == node.startOffset else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }

            reversedTokens.append(String(String.UnicodeScalarView(
                scalars[node.startOffset..<(node.startOffset + node.length)]
            )))
            reconstructedScalarCount += node.length
            currentIndex = previousIndex
        }

        guard reconstructedScalarCount == scalarCount else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }
        return reversedTokens.reversed()
    }
}
