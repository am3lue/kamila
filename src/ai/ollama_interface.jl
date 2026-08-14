"""
Ollama AI Interface Module for Kamila
Handles communication with Ollama and provides natural conversational responses
"""

module OllamaInterface

using HTTP
using JSON

export query_ollama,
    query_ollama_stream_raw,
    query_ollama_chat_stream,
    test_ollama_connection,
    get_model_info,
    explain_file_with_ai,
    generate_productivity_suggestions,
    generate_ai_daily_report,
    suggest_file_organization,
    get_ai_status,
    setup_kamila_model,
    get_ollama_latency,
    query_ollama_stream_raw

const OLLAMA_HOST = get(ENV, "OLLAMA_HOST", "http://localhost:11434")
const MODEL_NAME = "kamila1"
const KAMILA2_MODEL = "kamila2"
const CURL_MAX_TIME = get(ENV, "KAMILA_CURL_MAX_TIME", "15")

# A streamed item from an Ollama chat/generate stream. `is_thinking` marks
# reasoning output (e.g. gpt-oss `message.thinking`), which is shown to the
# user but never treated as the final answer.
struct StreamItem
    text::String
    is_thinking::Bool
end

StreamItem(text::String) = StreamItem(text, false)

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
function query_ollama(
    prompt::String;
    system_prompt::String = "",
    temperature::Float64 = 0.7,
    max_tokens::Int = 1000,
    model::String = MODEL_NAME,
)
    try
        if !test_ollama_connection()
            return "❌ I'm having trouble connecting right now. Make sure the AI service is running and try again!"
        end

        # Prepare the request payload
        payload = Dict(
            "model" => model,
            "prompt" => prompt,
            "system" => system_prompt,
            "stream" => false,
            "options" =>
                Dict("temperature" => temperature, "num_predict" => max_tokens),
        )

        # Make the API call with fresh connection (avoid stale pool issues)
        headers = ["Content-Type" => "application/json"]
        response = HTTP.request(
            "POST",
            "$OLLAMA_HOST/api/generate",
            headers,
            JSON.json(payload);
            readtimeout = 60,
            retry = false,
            reuse_limit = 0,
            require_ssl_verification = false,
        )

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
        if occursin("connection", error_msg) ||
           occursin("timeout", error_msg) ||
           occursin("network", error_msg)
            return "🤔 I'm having trouble connecting. Check if the AI service is running."
        else
            return "I'm experiencing some difficulties. Please try again in a moment."
        end
    end
end

"""
Query Ollama with streaming interface. Returns a Channel that yields the full response as one chunk.
(True token-by-token streaming will be added in Phase 4 with agent overhaul.)
"""
function query_ollama_stream(
    prompt::String;
    system_prompt::String = "",
    temperature::Float64 = 0.7,
    max_tokens::Int = 2000,
)
    channel = Channel{String}(1)

    @async try
        result = query_ollama(
            prompt,
            system_prompt = system_prompt,
            temperature = temperature,
            max_tokens = max_tokens,
        )
        if !isempty(result)
            put!(channel, result)
        end
    catch e
        put!(channel, "❌ Error: $e")
    finally
        close(channel)
    end

    return channel
end

"""
Query Ollama with TRUE token-by-token streaming using curl subprocess.
Returns a Channel that yields each token as it arrives.
"""
function query_ollama_stream_raw(
    prompt::String;
    model::String = MODEL_NAME,
    system_prompt::String = "",
    temperature::Float64 = 0.7,
    max_tokens::Int = 2000,
)
    channel = Channel{String}(32)

    @async try
        payload = Dict(
            "model" => model,
            "prompt" => prompt,
            "system" => system_prompt,
            "stream" => true,
            "options" =>
                Dict("temperature" => temperature, "num_predict" => max_tokens),
        )

        # Use curl subprocess for true streaming (HTTP.jl connection pool blocks streaming)
        cmd = `curl -s -N --max-time $CURL_MAX_TIME -X POST $OLLAMA_HOST/api/generate
               -H "Content-Type: application/json"
               -d $(JSON.json(payload))`

        open(cmd, "r") do io
            for line in eachline(io)
                try
                    data = JSON.parse(line)
                    chunk = get(data, "response", "")
                    if !isempty(chunk)
                        put!(channel, chunk)
                    end
                    if get(data, "done", false)
                        break
                    end
                catch
                    continue
                end
            end
        end
    catch e
        put!(channel, "❌ Stream error: $e")
    finally
        close(channel)
    end

    return channel
end

function query_ollama_chat_stream(
    messages;
    model::String = MODEL_NAME,
    temperature::Float64 = 0.7,
    max_tokens::Int = 2000,
)
    channel = Channel{StreamItem}(32)
    payload_file = tempname()

    @async try
        payload = Dict(
            "model" => model,
            "messages" => messages,
            "stream" => true,
            "options" =>
                Dict("temperature" => temperature, "num_predict" => max_tokens),
        )

        write(payload_file, JSON.json(payload))

        cmd = `curl -s -N --max-time $CURL_MAX_TIME -X POST $OLLAMA_HOST/api/chat
               -H "Content-Type: application/json"
               -d @$payload_file`

        open(cmd, "r") do io
            for line in eachline(io)
                try
                    data = JSON.parse(line)
                    if haskey(data, "message")
                        msg = data["message"]
                        # Reasoning output (e.g. gpt-oss "thinking") is surfaced
                        # to the user but never used as the final answer.
                        if haskey(msg, "thinking")
                            t = msg["thinking"]
                            if t isa String && !isempty(t)
                                put!(channel, StreamItem(t, true))
                            end
                        end
                        chunk = get(msg, "content", "")
                        chunk = replace(chunk, r"\\{2,}" => "\\")
                        if !isempty(chunk)
                            put!(channel, StreamItem(chunk, false))
                        end
                    end
                    if get(data, "done", false)
                        break
                    end
                catch
                    continue
                end
            end
        end
    catch e
        put!(channel, StreamItem("❌ Stream error: $e", false))
    finally
        close(channel)
        isfile(payload_file) && rm(payload_file, force = true)
    end

    return channel
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

        result = query_ollama(
            prompt,
            system_prompt = system_prompt,
            temperature = 0.3,
            max_tokens = 500,
        )
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

        result = query_ollama(
            prompt,
            system_prompt = system_prompt,
            temperature = 0.6,
            max_tokens = 400,
        )
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

        result = query_ollama(
            prompt,
            system_prompt = system_prompt,
            temperature = 0.8,
            max_tokens = 300,
        )
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
        file_categories = Dict{String,Vector{String}}()
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

        result = query_ollama(
            prompt,
            system_prompt = system_prompt,
            temperature = 0.5,
            max_tokens = 400,
        )
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
Create or update the Kamila models (kamila1 = online, kamila2 = offline).
"""
function setup_kamila_model()
    try
        if !test_ollama_connection()
            return Dict("success" => false, "error" => "Ollama server not available")
        end

        root = pwd()
        online_file = joinpath(root, "config", "Modelfile.online")
        offline_file = joinpath(root, "config", "Modelfile.offline")

        if !isfile(online_file)
            return Dict("success" => false, "error" => "Modelfile.online not found")
        end
        if !isfile(offline_file)
            return Dict("success" => false, "error" => "Modelfile.offline not found")
        end

        results = String[]
        for (name, file) in ((MODEL_NAME, online_file), (KAMILA2_MODEL, offline_file))
            cmd = `ollama create $name -f $file`
            read(cmd, String)
            push!(results, name)
        end

        return Dict(
            "success" => true,
            "message" => "Models created/updated: " * join(results, ", "),
        )
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
        "model_name" => MODEL_NAME,
    )

    if connection_ok
        model_info = get_model_info()
        if haskey(model_info, "models")
            status["available_models"] = [get(m, "name", "") for m in model_info["models"]]
        end
    end

    return status
end

"""
Measure Ollama API response latency in milliseconds
"""
function get_ollama_latency()
    try
        start = time_ns()
        HTTP.request("GET", "$OLLAMA_HOST/api/tags", timeout = 2)
        elapsed = (time_ns() - start) / 1_000_000
        return round(elapsed, digits = 1)
    catch
        return -1.0
    end
end

end # module
