# Kamila - Personal Terminal Assistant Manual

## 1. Introduction
Kamila is your K.A.M.I.L.A (Kind, Adaptive, Mind, Integrating, Logic, Assistant) - a personal terminal assistant designed for Linux users. It combines task management, system monitoring, file organization, and AI capabilities into a unified, colorful Terminal User Interface (TUI).

## 2. Getting Started

### Installation & Launch
1.  **Dependencies**: Ensure `julia` is installed on your system. For AI features, you need `ollama` installed and running.
2.  **Launch**: Run the following command from the project root:
    ```bash
    bin/kamila
    ```

### Authentication
*   **First Run**: Kamila will ask you to create a secure password (minimum 4 characters).
*   **Login**: Enter your password to access the dashboard.
*   **Reset**: If you forget your password, delete the `~/.kamila_config.json` file to reset authentication.

## 3. Features

### 📋 1. Task Manager
Manage your daily to-dos efficiently.
*   **Add Task**: Create new tasks with title, description, category, priority (1-4), and estimated time.
*   **Complete Task**: Mark tasks as done to update your daily stats.
*   **Daily Schedule**: Generate an optimized timeline for your day based on task priorities and time estimates.
*   **Overdue Tasks**: View tasks that missed their due dates.
*   **Export**: Save your tasks to a JSON file for backup.

### 💾 2. Memory & Achievements
Gamify your productivity.
*   **Goals**: Set long-term goals and track them.
*   **Achievements**: Unlock achievements by completing tasks and goals (e.g., "Goal Completed").
*   **Productivity Stats**: View your completion rates and "useful activity" percentage.
*   **Memory Summary**: Get a snapshot of your overall progress.
*   **Storage**: SQLite database (schema v1) with WAL mode for crash safety; JSON export/compat view at `~/.kamila_memory.json` for backup and portability.

### 🖥️ 3. System Status
Monitor your Linux machine's health.
*   **Dashboard**: View CPU, Memory, and Disk usage in real-time.
*   **Health Score**: Get a 0-100 health score for your system.
*   **Monitor Resources**: Run a live monitor that updates every second (press Ctrl+C to stop).
*   **Alerts**: Check for critical warnings about high resource usage.

### 📁 4. Desktop Organization
Keep your workspace clean.
*   **Auto-Organize**: Automatically move files on your Desktop into folders like `Images`, `Documents`, `Code`, and `Archives`.
*   **Suggestions**: Get AI-powered advice on how to better structure your files.
*   **Health Report**: Assess how cluttered your desktop is and get a health score.
*   **Clean Old Files**: Identify and move files older than 30 days.
*   **Security**: Kamila operates strictly within allowed directories (~/Desktop, ~/Documents, etc.) to keep your system safe.

### 🤖 5. AI Assistant
Powered by Ollama (local AI).
*   **Productivity Suggestions**: Get AI analysis of your work habits.
*   **File Explanation**: Ask AI to explain the contents of any text file on your system.
*   **Daily Report**: Receive an encouraging AI-generated summary of your day.
*   **Connection**: Requires `ollama serve` to be running. Kamila routes to `kamila1` (online, gpt-oss cloud) first and automatically falls back to `kamila2` (offline, local qwen3:8b) if the online model errors or times out (default 15s, tunable via `KAMILA_CURL_MAX_TIME`).

### 🧠 6. Thinking Display
When the model emits reasoning (e.g. gpt-oss `message.thinking`), Kamila shows it live as a dimmed `🧠 Thinking… (click to expand)` line.
*   **Click** the thinking line to expand or collapse the full reasoning text.
*   **Click any other message line** to copy it to the clipboard.
*   Reasoning is never included in saved chat history or the final answer.

### 📝 7. Chat Input & Recall
The chat input is a multiline text area.
*   **Enter** sends your message.
*   **Ctrl+O** inserts a newline (for multi-line prompts).
*   **↑ / ↓** (or **Ctrl+P / Ctrl+N**) cycle through your previously submitted prompts — the prompt recall ring.
*   **Ctrl+C** (with the chat log focused) copies the last assistant response; **Ctrl+↑/↓** scroll the chat log.
*   Chat history is restored automatically on launch from the backend session, so previous exchanges reappear when you restart the TUI.

### ⚙️ 8. Settings
Configure your experience.
*   **Change Password**: Update your login credentials.
*   **Security Report**: Verify that Kamila's file access restrictions are active.
*   **Reset Auth**: Clear your login configuration.

### 🤖 9. Agent Mode
Interactive AI Agent.
*   **Chat Interface**: Talk to Kamila naturally.
*   **Tools**: Kamila can use tools to Check files, Run commands, and Manage tasks for you.
*   **Autonomous**: Can perform multi-step actions to help you.

## 4. Troubleshooting

*   **Blank Screens/UI Glitches**: Ensure your terminal supports true color and standard ANSI escape codes.
*   **AI Not Working**: Verify `ollama` is installed and the server is running (`ollama serve`). Run "Test AI connection" in the AI menu.
*   **File Access Errors**: Kamila is sandboxed. It can only read/write in your home directory's Desktop, Documents, Pictures, Downloads, Trash, and Codes folders.
*   **Memory/Database Issues**: Memory is stored in SQLite at `~/.local/state/kamila/kamila.db`. The JSON compat view is at `~/.kamila_memory.json`. If corruption is suspected, delete the DB file (it will be recreated from the JSON view on next start) or run `./bin/kamila --check` for diagnostics.

## 5. Keyboard Shortcuts
*   **0-6**: Select menu options.
*   **Enter**: Send message / confirm selections.
*   **Ctrl+O**: Newline in the chat input.
*   **↑ / ↓ (or Ctrl+P / Ctrl+N)**: Cycle prompt recall ring.
*   **Ctrl+C**: Copy last response (chat log focused) / stop monitoring processes.
*   **Tab**: Focus the chat input.
*   **F5**: Refresh panels, **F10**: toggle logs, **F11**: toggle permissions panel, **Ctrl+T**: toggle side panels.

---
*Created by Blue Francis*
