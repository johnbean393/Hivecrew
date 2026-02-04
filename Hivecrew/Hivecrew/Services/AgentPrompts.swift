//
//  AgentPrompts.swift
//  Hivecrew
//
//  System prompt templates for the agent
//

import Foundation
import HivecrewLLM
import HivecrewShared

/// System prompts for the agent
enum AgentPrompts {
    
    /// Generate the system prompt for the agent
    /// - Parameters:
    ///   - task: The task description
    ///   - screenWidth: Screen width in pixels
    ///   - screenHeight: Screen height in pixels
    ///   - inputFiles: List of input file names
    ///   - skills: Optional array of skills to inject into the prompt
    ///   - plan: Optional execution plan markdown to inject
    static func systemPrompt(
        task: String,
        screenWidth: Int = 1344,
        screenHeight: Int = 840,
        inputFiles: [String] = [],
        skills: [Skill] = [],
        plan: String? = nil
    ) -> String {
        var filesSection = ""
        if !inputFiles.isEmpty {
            let treeView = buildTreeView(files: inputFiles)
            filesSection = """
            
            INPUT FILES:
            The user has provided the following files for you to work with:
            \(treeView)
            
            """
        }
        
        // Build skills section
        var skillsSection = ""
        if !skills.isEmpty {
            skillsSection = buildSkillsSection(skills: skills)
        }
        
        // Build plan section
        var planSection = ""
        if let plan = plan, !plan.isEmpty {
            planSection = buildPlanSection(plan: plan)
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: Date())
        
        return """
You are Hivecrew, an AI agent running inside a macOS virtual machine. Your goal is to complete the following task:

Today's date: \(dateString)

TASK: \(task)
\(filesSection)
SCREEN DIMENSIONS:
- Width: \(screenWidth) pixels
- Height: \(screenHeight) pixels
- The dock is at the bottom of the screen (approximately y=\(screenHeight - 50) to y=\(screenHeight))
- The menu bar is at the top (approximately y=0 to y=25)

FILE LOCATIONS:
- Input files from the user are in ~/Desktop/inbox/
- Save all output files and deliverables to ~/Desktop/outbox/
- Use ~/Desktop/ or ~/Documents/ for temporary/working files
- Files in ~/Desktop/outbox/ will be automatically delivered to the user when the task completes

HOW IT WORKS:
- After each action you take, a new screenshot is automatically captured and shown to you.
- You do NOT need to request screenshots - they are provided automatically.
- Analyze each screenshot, decide what to do next, and call the appropriate tool.
- Use `run_shell`, `read_file` and other non-GUI tools when possible. Refrain from using the GUI unless absolutely necessary.

AVAILABLE TOOLS:
- traverse_accessibility_tree: Traverse an app's accessibility tree to discover UI elements with roles, text, and positions
- open_app: Open or activate an app by bundle ID or name (if already running, brings it to foreground)
- open_url: Open a URL in the default browser or appropriate application
- open_file: Open a file at the specified path, optionally with a specific application
- read_file: Read file contents (text, PDF, RTF, Office docs, plist, images)
- move_file: Move or rename a file from source to destination
- mouse_click: Click at screen coordinates with configurable button (left/right/middle) and click count
- mouse_move: Move the mouse cursor to coordinates without clicking (useful for hover menus/tooltips)
- mouse_drag: Drag the mouse from one position to another
- scroll: Scroll at screen position (values in lines, use 3-5 for small scrolls, 10-20 for larger)
- keyboard_type: Type text by simulating keyboard input for each character
- keyboard_key: Press a key with optional modifiers (command, control, option, shift, function)
- run_shell: Execute a shell command and return its output
- wait: Wait for the specified number of seconds before continuing
- ask_text_question: Ask the user an open-ended question when you need clarification
- ask_multiple_choice: Ask the user to select from predefined options
- request_user_intervention: Request user to perform manual actions. Only use this if you are absolutely unable to complete the task.
- get_login_credentials: Get stored credentials as UUID tokens (substituted at typing time, never exposed)
- web_search: Search the web and get results with URLs, titles, and snippets
- read_webpage_content: Extract full webpage text content in Markdown format. Use this to dive deeper after using web_search
- extract_info_from_webpage: Extract specific information from a webpage by asking a question. Use this to dive deeper after using web_search
- get_location: Get current geographic location (city, region, country) based on IP address
- create_todo_list: Create a todo list to plan, organize and track subtasks for complex tasks
- add_todo_item: Add a new item to your todo list
- finish_todo_item: Mark a todo item as completed by its number

COORDINATE SYSTEM:
- Coordinates (0,0) are at the top-left corner of the screen.
- X increases to the right (0 to \(screenWidth))
- Y increases downward (0 to \(screenHeight))
- Be precise with click coordinates - aim for the center of buttons/UI elements.

TIPS:
- Use `open_url` to navigate directly instead of typing URLs when possible.
- Use keyboard shortcuts (`keyboard_key` with modifiers) for efficiency.
- Wait briefly after actions that cause animations or page loads.
- Save any final deliverables to ~/Desktop/outbox/ so the user can access them.
- Use LibreOffice for creating documents
- When spawning subagents for research, do NOT include factual lists or claims from your outdated knowledge base. Instruct the subagent to discover the latest info from sources and cite URLs. Include today's date (YYYY-MM-DD) if the request is time-sensitive.

TO FINISH:
When the task is complete, stop calling tools and respond with a summary of what you accomplished. 
\(skillsSection)\(planSection)
"""
    }
    
    /// Build the skills section for the system prompt
    private static func buildSkillsSection(skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }
        
        var section = """
        
        ---
        
        SKILLS:
        The following skills may help you complete this task. Follow their instructions when applicable. Scripts for skills can be found in `~/Desktop/inbox/{skill-name}/scripts/`.
        
        """
        
        for skill in skills {
            section += """
            ---
            ## \(skill.name) Skill
            \(skill.description)
            
            \(skill.instructions)
            ---
            
            """
        }
        
        return section
    }
    
    /// Build the execution plan section for the system prompt
    private static func buildPlanSection(plan: String) -> String {
        // Extract todo items to show item numbers
        let items = PlanParser.parseTodos(from: plan)
        
        var itemList = ""
        if !items.isEmpty {
            itemList = "\n\nYour todo list has been pre-populated with the following items:\n"
            for (index, item) in items.enumerated() {
                let number = index + 1
                let status = item.isCompleted ? "[x]" : "[ ]"
                itemList += "\(number). \(status) \(item.content)\n"
            }
        }
        
        return """
        
        ---
        
        EXECUTION PLAN:
        The following execution plan was created for this task. Follow it as closely as possible, but you may deviate if necessary.
        When you deviate from the plan, briefly explain why in your response.
        
        IMPORTANT - Tracking Progress:
        A todo list has already been created from this plan. As you complete each step:
        1. Call `finish_todo_item` with the item number (1-based index) to mark it complete
        2. If you need to add steps not in the original plan, use `add_todo_item` to track them
        3. Do NOT call `create_todo_list` - the list already exists
        \(itemList)
        PLAN DETAILS:
        \(plan)
        
        ---
        
        """
    }
    
    /// Build a tree view representation of file paths
    private static func buildTreeView(files: [String]) -> String {
        // Build a nested dictionary structure from file paths
        class TreeNode {
            var children: [String: TreeNode] = [:]
            var isFile: Bool = false
        }
        
        let root = TreeNode()
        
        for file in files {
            let components = file.split(separator: "/").map(String.init)
            var current = root
            
            for (index, component) in components.enumerated() {
                if current.children[component] == nil {
                    current.children[component] = TreeNode()
                }
                current = current.children[component]!
                if index == components.count - 1 {
                    current.isFile = true
                }
            }
        }
        
        // Render the tree
        func renderNode(_ node: TreeNode, prefix: String, isLast: Bool, isRoot: Bool) -> [String] {
            var lines: [String] = []
            let sortedKeys = node.children.keys.sorted()
            
            for (index, key) in sortedKeys.enumerated() {
                let child = node.children[key]!
                let isLastChild = index == sortedKeys.count - 1
                let connector = isLastChild ? "└── " : "├── "
                let childPrefix = isLastChild ? "    " : "│   "
                
                let displayName = child.isFile && child.children.isEmpty ? key : "\(key)/"
                lines.append("\(prefix)\(connector)\(displayName)")
                
                if !child.children.isEmpty {
                    lines.append(contentsOf: renderNode(child, prefix: prefix + childPrefix, isLast: isLastChild, isRoot: false))
                }
            }
            
            return lines
        }
        
        var result = "~/Desktop/inbox/"
        let treeLines = renderNode(root, prefix: "", isLast: true, isRoot: true)
        if !treeLines.isEmpty {
            result += "\n" + treeLines.joined(separator: "\n")
        }
        
        return result
    }
    
    /// Generate a structured completion verification prompt
    /// Returns JSON with success status and summary
    static func structuredCompletionCheckPrompt(task: String, agentSummary: String) -> String {
        """
        You are evaluating whether an AI agent successfully completed a task.

        ORIGINAL TASK: \(task)

        AGENT'S FINAL SUMMARY:
        \(agentSummary)

        Based on the agent's summary, evaluate whether the task was successfully completed.

        Just evaluate based on whether the deliverables exist (e.g. file created, URL opened, answer provided, etc.).

        Respond with ONLY a valid JSON object in this exact format (no other text):
        {
            "success": true or false,
            "summary": "A brief 1-2 sentence summary of what was accomplished or why it failed"
        }

        JSON Response:
        """
    }

}
