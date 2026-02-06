# KAMILA - Project Requirements

## 1. Identity & Core Philosophy
**Acronym:**
*   **K** - Kind
*   **A** - Adaptive
*   **M** - Mind
*   **I** - Integrating
*   **L** - Logic
*   **A** - Assistant

**Description:** Kamila is a personal terminal assistant designed to be easily accessible, fast, and lightweight. It acts as an intelligent layer (powered by Ollama and Julia) to help manage the user's digital life.

## 2. Core Capabilities
Kamila should help effectively with the PC in the easiest way possible:
*   **File Management:**
    *   Create and delete files.
    *   Organize files and folders on the Desktop efficiently.
    *   Read files (even system files) and "translate" or explain them simply.
*   **Task & Time Management:**
    *   Create optimized timetables based on tasks.
    *   Remind the user of pending tasks.
    *   Generate daily tasks.
    *   Arrange and organize project ideas.
*   **System Interaction:**
    *   Check and report system status daily.
    *   Display a visually appealing TUI (Text User Interface).

## 3. Access & Security Constraints
*   **Operating System:**
    *   **Strictly Linux only.**
    *   Must be "blocked" or non-functional on Windows.
    *   Optimized for Arch Linux (may have partial functionality or be harder to configure on non-Arch distros).
    *   Should implement an OS check mechanism.
*   **File System Access Scope:**
    *   Read/Write access strictly limited to specific user directories:
        *   `~/Desktop`
        *   `~/Pictures`
        *   `~/Documents`
        *   `~/Downloads`
        *   `~/Trash` (or Recycle Bin)
        *   `~/Codes`
    *   **Write Restriction:** Should only write files within the home directory scope.
*   **Authentication:**
    *   Must have a password/authentication mechanism to reject unauthorized users ("trespassers").

## 4. Memory & persistence
Kamila requires a persistent memory system stored in the home directory (e.g., a `.json` file).
*   **Summarization:** When not in use, Kamila should generate summaries of interactions.
*   **Data Points to Track:**
    *   Tasks for "Blue" (User alias?).
    *   Today's Achievements.
    *   Future Goals.
    *   Productivity Metrics (% of useful vs. non-useful activities).

## 5. Technology Stack

*   **Language:** Julia (Primary logic and customization).

*   **AI Backend:** Ollama running `qwen2.5-coder:0.5b`.

    *   **Configuration:** Requires a custom **Modelfile** to define system prompts and behavior for seamless integration with Julia.

*   **Shell Integration:** Bash or Zsh compatibility.

*   **Interface:** TUI (Terminal User Interface) with good coloring/styling.
