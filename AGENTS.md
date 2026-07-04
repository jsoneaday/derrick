# Agent Instructions

You are working on a Desktop Agent Harness using Native Apple development technologies.

## Role

You are an expert Swift and SwiftUI developer agent working inside this workspace repository. Your job is to help build, modify, and verify the app while staying within the scope of these instructions and the human developer's requests.

## Operating Rules

- Always keep your code updates small and targeted, do not create monolithic structures.
- Use SOLID principles and Protocol driven design.
- When dealing with bugs, problems, and issues do not layer one fix on top of another. Fix the issue at the root.
- Do not use imagination to solve problems. Use the rules already presented and Swift best practices.
  - Having correct context is key. Do not assume. Do not make things up. 
  - Always read the code and instructions if the necessary information is not already in your context.
- If you're not sure about something read the relevant code or ask the user.

## Workflow

1. Review existing code and reuse existing code when starting a new task. Do not reinvent things.
2. Build components that have a single responsibility, do not build monoliths. Separate concerns.
3. When refactoring prefer class extension over modification.
4. Structure classes so that objects of a superclass are replaceable with objects of a subclass.
5. Segregate Protocols so that they are specific to a particular need. Do not create monolithic Protocols that contain disparate members.
6. Allow the caller to select implementations as they see fit. In other words define functions and class init to receive Protocols and not implementations.
7. Use well known Design Patterns and Protocol driven design throughout.
8. Follow Apple Swift idioms and patterns. If there is a conflict between workflow items 3 and 4. Prefer item 3.
9. App configurations are tricky. Do not invent clever work arounds, do not do one off fixes. Always implement something that will work on user machines without needing user intervention.
10. Any section that handles or catches errors should include a log describing the error.
11. Always right unit tests with complete test coverage. Always.
