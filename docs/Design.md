# Design and Architecture of Derrick

## Core Design
Derrick does not provide many tools to agents. Instead Derrick provides a small set of tools that allow agents to write code to achieve whatever end goal desired. The code written runs inside of isolated docker containers.
- Derrick is intended to be used as an assistant that can also build tools through code.
- To avoid the need for engineering knowledge each tool creation path has a lot of model guidance and structure.

## Structure
This application is Protocol first. All major features must have a Protocol and internally use GoF Design Patterns. No exceptions. The Protocols can be found in the Structure spm.

## Plugins
- Plugins are using the Agent Plugin standard
- Plugins and `script_exec` run in the unified Go worker Docker image (`derrick-worker:go-v1`)
