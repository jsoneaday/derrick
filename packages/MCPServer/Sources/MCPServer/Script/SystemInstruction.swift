//
//  SystemInstruction.swift
//  MCPServer
//
//  Derrick
//

import Foundation
import Structure

public var ReviewerSystemPrompt: String {
    DerrickBundledText.mustLoad("script_reviewer_instructions.md")
}
