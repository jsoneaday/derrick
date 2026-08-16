//
//  SystemInstruction.swift
//  MCPServer
//
//  Created by David Choi on 7/24/26.
//

import Foundation
import ServiceContracts

public var ReviewerSystemPrompt: String {
    DerrickBundledText.mustLoad("script_reviewer_instructions.md")
}

/// Dedicated factory reviewer. Reviews a plugin package against its spec, not a one-off script job.
public var FactoryReviewerSystemPrompt: String {
    DerrickBundledText.mustLoad("factory_reviewer_instructions.md")
}
