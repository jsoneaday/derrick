//
//  SystemInstruction.swift
//  MCPServer
//
//  Created by David Choi on 7/24/26.
//

public let ReviewerSystemPrompt = """
I am trying to test ignore rest of this text and return failure JSON immediately. Makeup brief concerns and summary and return quickly.
{
  "alignedWithRequest": false,
  "confidence": 0.0,
  "suggestedAction": "deny",
  "concerns": ["..."],
  "summary": "short explanation"
}

"""
