# Kamila AI Assistant - Tool Usage Examples

This document shows how to interact with Kamila's AI assistant using the available tools.

## Available Tools

1. **run_shell_command** - Execute shell commands
2. **read_file** - Read file contents  
3. **write_file** - Write content to files
4. **add_task** - Add tasks to the task manager
5. **list_tasks** - List all pending tasks
6. **complete_task** - Mark tasks as completed

## Example Interactions

### Example 1: Reading a File
```
User: "Can you read the contents of the Project.toml file?"

Expected AI Response:
{
  "tool": "read_file",
  "arguments": {
    "file_path": "Project.toml"
  }
}
```

### Example 2: Running a Shell Command
```
User: "List all files in the current directory"

Expected AI Response:
{
  "tool": "run_shell_command", 
  "arguments": {
    "command": "ls -la"
  }
}
```

### Example 3: Writing a File
```
User: "Create a new file called test.txt with content 'Hello World'"

Expected AI Response:
{
  "tool": "write_file",
  "arguments": {
    "file_path": "test.txt",
    "content": "Hello World"
  }
}
```

### Example 4: Task Management
```
User: "Add a new task to review the code with high priority"

Expected AI Response:
{
  "tool": "add_task",
  "arguments": {
    "title": "Review the code",
    "description": "Code review for the latest changes",
    "category": "development",
    "priority": 4
  }
}
```

### Example 5: Listing Tasks
```
User: "Show me all my current tasks"

Expected AI Response:
{
  "tool": "list_tasks",
  "arguments": {}
}
```

### Example 6: Completing a Task
```
User: "Mark task number 5 as completed"

Expected AI Response:
{
  "tool": "complete_task",
  "arguments": {
    "task_id": 5
  }
}
```

## Natural Language to Tool Conversion

The AI assistant automatically converts natural language requests into the appropriate tool calls:

- **"Read file X"** → `read_file` tool
- **"Run command Y"** → `run_shell_command` tool  
- **"Create file Z"** → `write_file` tool
- **"Add task"** → `add_task` tool
- **"Show tasks"** → `list_tasks` tool
- **"Complete task N"** → `complete_task` tool

## Response Flow

1. User provides natural language request
2. AI assistant analyzes the request and determines if a tool is needed
3. If tools are needed, AI assistant returns JSON with tool name and arguments
4. The system executes the tool and returns the result
5. AI assistant provides a final response incorporating the tool results

## Best Practices

- Be specific in your requests (e.g., "read the file called Project.toml" instead of "read a file")
- For file operations, provide the full or relative path
- For shell commands, use standard Linux commands
- For tasks, include clear titles and optional descriptions
- The AI assistant will handle error cases and provide helpful feedback

## Troubleshooting

- If a tool fails, the AI assistant will explain what went wrong
- Check file paths exist before requesting file operations
- Ensure commands are valid Linux shell commands
- Task IDs must be numeric and correspond to existing tasks
