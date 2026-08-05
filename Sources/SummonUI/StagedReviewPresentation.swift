import Foundation
import SummonCore

public struct StagedReviewPresentation: Sendable, Equatable {
    public let proposalID: String
    public let title: String
    public let reviewedText: String

    public init(proposal: PersistedStagedProposal) throws {
        proposalID = proposal.id
        title = "Staged (\(proposal.rung)) — edit the exact action before accepting"
        if proposal.rung == "agent" {
            guard let data = proposal.output.data(using: .utf8) else {
                throw CoreError.schemaValidation("staged action is not UTF-8")
            }
            let gate = SchemaGate()
            reviewedText = try gate.reviewedText(for: gate.decodeReviewedAction(from: data))
        } else {
            reviewedText = proposal.output
        }
    }

    public static func showsChrome(
        _ hasQuery: Bool,
        _ hasStagedProposal: Bool,
        _ footerMessage: String?
    ) -> Bool {
        hasQuery || hasStagedProposal || !(footerMessage?.isEmpty ?? true)
    }
}
