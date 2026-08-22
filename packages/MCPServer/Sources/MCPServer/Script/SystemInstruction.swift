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
