"""
Ollama AI Interface Module for Kamila
Handles communication with Ollama and provides natural conversational responses
"""

module OllamaInterface

using HTTP
using JSON

export query_ollama, test_ollama_connection, get_model_info, explain_file_with_ai,
       generate_productivity_suggestions, generate_ai_daily_report, 
       suggest_file_organization, get_ai_status, setup_kamila_model

const OLLAMA_HOST = get(ENV, "OLLAMA_HOST", "http://localhost:11434")
const MODEL_NAME = "kamila:latest"

"""
Test connection to Ollama server
"""
function test_ollama_connection()
    try
        response = HTTP.get("$OLLAMA_HOST/api/tags")
        return response.status == 200
    catch
        return false
    end
end

"""
Get available models from Ollama
"""
function get_model_info()
    try
        if !test_ollama_connection()
            return Dict("error" => "Ollama server not available")
        end
        
        response = HTTP.get("$OLLAMA_HOST/api/tags")
        data = JSON.parse(String(response.body))
        
        return data
    catch e
        return Dict("error" => "Failed to get model info: $e")
    end
end

"""
Query Ollama with a prompt - returns natural conversation instead of JSON
"""
function query_ollama(prompt::String; system_prompt::String="", temperature::Float64=0.7, max_tokens::Int=1000)
    try
        if !test_ollama_connection()
            return "❌ I'm having trouble connecting right now. Make sure the AI service is running and try again!"
        end
        
        # Prepare the request payload
        payload = Dict(
            "model" => MODEL_NAME,
            "prompt" => prompt,
            "system" => system_prompt,
            "stream" => false,
            "options" => Dict(
                "temperature" => temperature,
                "num_predict" => max_tokens
            )
        )
        
        # Make the API call
        headers = ["Content-Type" => "application/json"]
        response = HTTP.post("$OLLAMA_HOST/api/generate", 
                           headers=headers, 
                           body=JSON.json(payload))
        
        if response.status == 200
            result = JSON.parse(String(response.body))
            ai_response = get(result, "response", "")
            # Return just the conversational response, no JSON structure
            if !isempty(ai_response)
                return ai_response
            else
                return "I seem to be having trouble processing that. Could you try rephrasing your question?"
            end
        else
            return "I'm having a technical hiccup right now. Let me try again in a moment!"
        end
    catch e
        error_msg = string(e)
        if occursin("connection", error_msg) || occursin("timeout", error_msg) || occursin("network", error_msg)
            return "🤔 I'm having trouble connecting. Check if the AI service is running."
        else
            return "I'm experiencing some difficulties. Please try again in a moment."
        end
    end
end

"""
Ask AI to explain file content
"""
function explain_file_with_ai(file_path::String, file_content::String)
    try
        system_prompt = "You are Kamila, a helpful file analysis assistant. Explain this file content in simple terms, focusing on its purpose and key information."
        
        prompt = """
        Please analyze and explain this file:
        
        File: $(basename(file_path))
        Path: $file_path
        
        Content:
        ```
        $file_content
        ```
        
        Provide a clear, concise explanation of what this file contains and its purpose.
        """
        
        result = query_ollama(prompt, system_prompt=system_prompt, temperature=0.3, max_tokens=500)
        return result
    catch e
        return "❌ Error analyzing file: $e"
    end
end

"""
Generate productivity suggestions using AI
"""
function generate_productivity_suggestions(tasks::Vector, stats::Dict)
    try
        system_prompt = "You are Kamila, a productivity assistant. Based on the user's tasks and statistics, provide helpful suggestions to improve their productivity."
        
        # Format tasks for AI consumption
        task_summary = "Current Tasks:\n"
        for task in tasks
            task_summary *= "- $(task.title) (Priority: $(task.priority), Category: $(task.category))\n"
        end
        
        prompt = """
        Based on this productivity data, suggest improvements:
        
        $task_summary
        
        Current Statistics:
        - Total tasks: $(get(stats, "total_tasks", 0))
        - Completion rate: $(get(stats, "completion_rate", 0))%
        - Pending tasks: $(get(stats, "pending_tasks", 0))
        
        Provide 3-5 actionable suggestions to help improve productivity and task completion.
        Keep suggestions brief and practical.
        """
        
        result = query_ollama(prompt, system_prompt=system_prompt, temperature=0.6, max_tokens=400)
        return result
    catch e
        return "❌ Error generating suggestions: $e"
    end
end

"""
Generate daily report with AI insights
"""
function generate_ai_daily_report(tasks::Vector, memory_stats::Dict, system_info::Dict)
    try
        system_prompt = "You are Kamila, a helpful daily assistant. Provide encouraging and insightful commentary on the user's day and progress."
        
        prompt = """
        Generate a daily report with insights:
        
        Task Summary:
        - Tasks completed: $(length(filter(t -> t.completed, tasks)))
        - Tasks pending: $(length(filter(t -> !t.completed, tasks)))
        - Productivity percentage: $(get(memory_stats, "productivity_percentage", 0))%
        
        Memory Stats:
        - Achievements: $(length(get(memory_stats, "achievements", [])))
        - Goals active: $(get(memory_stats, "active_goals", 0))
        
        System Info:
        - Memory usage: $(round(get(system_info, "free_memory_gb", 0) / get(system_info, "total_memory_gb", 1) * 100, digits=1))% free
        
        Provide an encouraging daily summary with 2-3 key insights and suggestions.
        """
        
        result = query_ollama(prompt, system_prompt=system_prompt, temperature=0.8, max_tokens=300)
        return result
    catch e
        return "❌ Error generating daily report: $e"
    end
end

"""
Get AI assistance for file organization suggestions
"""
function suggest_file_organization(directory::String, files::Vector{String})
    try
        system_prompt = "You are Kamila, a file organization assistant. Suggest how to organize files logically."
        
        # Categorize files by extension
        file_categories = Dict{String, Vector{String}}()
        for file in files
            ext = lowercase(splitext(file)[2])
            if !haskey(file_categories, ext)
                file_categories[ext] = String[]
            end
            push!(file_categories[ext], file)
        end
        
        prompt = """
        Analyze this directory contents and suggest organization:
        
        Directory: $directory
        
        Files by type:
        """
        
        for (ext, files_list) in file_categories
            prompt *= "- $ext files: $(join(files_list, ", "))\n"
        end
        
        prompt *= "\nSuggest a logical folder organization for these files. Keep suggestions practical and simple."
        
        result = query_ollama(prompt, system_prompt=system_prompt, temperature=0.5, max_tokens=400)
        return result
    catch e
        return "❌ Error generating organization suggestions: $e"
    end
end

"""
Check if the Kamila model is available
"""
function is_kamila_model_available()
    try
        models = get_model_info()
        if haskey(models, "models")
            for model in models["models"]
                if get(model, "name", "") == MODEL_NAME
                    return true
                end
            end
        end
        return false
    catch
        return false
    end
end

"""
Create or update the Kamila model using Modelfile
"""
function setup_kamila_model()
    try
        if !test_ollama_connection()
            return Dict("success" => false, "error" => "Ollama server not available")
        end
        
        # Check if Modelfile exists
        modelfile_path = joinpath(pwd(), "Modelfile")
        if !isfile(modelfile_path)
            return Dict("success" => false, "error" => "Modelfile not found")
        end
        
        # Create the model
        cmd = `ollama create $MODEL_NAME -f $modelfile_path`
        result = read(cmd, String)
        
        return Dict("success" => true, "message" => "Kamila model created/updated successfully")
    catch e
        return Dict("success" => false, "error" => "Failed to setup model: $e")
    end
end

"""
Generate AI status report
"""
function get_ai_status()
    connection_ok = test_ollama_connection()
    model_available = is_kamila_model_available()
    
    status = Dict(
        "ollama_running" => connection_ok,
        "kamila_model_available" => model_available,
        "host" => OLLAMA_HOST,
        "model_name" => MODEL_NAME
    )
    
    if connection_ok
        model_info = get_model_info()
        if haskey(model_info, "models")
            status["available_models"] = [get(m, "name", "") for m in model_info["models"]]
        end
    end
    
    return status
end

end # module
