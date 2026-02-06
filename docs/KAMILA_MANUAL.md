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
*   **Connection**: Requires `ollama serve` to be running. Kamila uses the `kamila` custom model (based on qwen2.5-coder).

### ⚙️ 6. Settings
Configure your experience.
*   **Change Password**: Update your login credentials.
*   **Security Report**: Verify that Kamila's file access restrictions are active.
*   **Reset Auth**: Clear your login configuration.

### 🤖 7. Agent Mode
Interactive AI Agent.
*   **Chat Interface**: Talk to Kamila naturally.
*   **Tools**: Kamila can use tools to Check files, Run commands, and Manage tasks for you.
*   **Autonomous**: Can perform multi-step actions to help you.

## 4. Troubleshooting

*   **Blank Screens/UI Glitches**: Ensure your terminal supports true color and standard ANSI escape codes.
*   **AI Not Working**: Verify `ollama` is installed and the server is running (`ollama serve`). Run "Test AI connection" in the AI menu.
*   **File Access Errors**: Kamila is sandboxed. It can only read/write in your home directory's Desktop, Documents, Pictures, Downloads, Trash, and Codes folders.

## 5. Keyboard Shortcuts
*   **0-6**: Select menu options.
*   **Enter**: Confirm selections or dismiss prompts.
*   **Ctrl+C**: Stop monitoring processes (safely handles interruptions).

---
*Created by Kamila Assistant Dev Team*
