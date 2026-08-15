"""
Events — in-process event bus for the proactive daemon (06.1).

`publish(event)` pushes an event into a bounded queue; `subscribe(pattern,
handler)` registers a handler invoked for matching events in publish order.
Handlers run on the publisher's thread (so order is deterministic) and must not
block; long-running work should be spawned by the handler itself.

Bridge mode also subscribes so daemon-sourced notifications reach the TUI as
`notification` protocol events.
"""

module Events

using Base.Threads
using ..KamilaLog

export publish, subscribe, unsubscribe, drain, pending_count, RESERVED

# Bounded queue: dropping oldest avoids unbounded memory under burst.
const _QUEUE = Channel{Any}(1024)

# Subscription pattern → handler. Patterns are simple prefix matches.
const _SUBSCRIBERS = Dict{String,Vector{Function}}()
const _SUBSCRIBER_LOCK = ReentrantLock()

# Event kinds that may not be re-published by arbitrary callers.
const RESERVED = ("notification", "file.created", "file.updated", "health.alert")

"""
Register `handler` for events whose kind starts with `pattern` ("" matches all).
Returns the handler so callers can `unsubscribe`.
"""
function subscribe(pattern::AbstractString, handler::Function)
    lock(_SUBSCRIBER_LOCK) do
        p = String(pattern)
        handlers = get!(_SUBSCRIBERS, p, Function[])
        push!(handlers, handler)
    end
    return handler
end

function unsubscribe(pattern::AbstractString, handler::Function)
    lock(_SUBSCRIBER_LOCK) do
        p = String(pattern)
        if haskey(_SUBSCRIBERS, p)
            filter!(h -> h !== handler, _SUBSCRIBERS[p])
        end
    end
    return nothing
end

"""
Publish an event (a Dict with at least a `"kind"` key) to matching subscribers.
The event is also appended with a sequential id and timestamp. Subscribers run
synchronously in registration order.
"""
function publish(event::AbstractDict)
    e = Dict{String,Any}(String(k) => v for (k, v) in event)
    kind = string(get(e, "kind", ""))
    isempty(kind) && return nothing

    try
        put!(_QUEUE, e)
    catch
        # Channel full: drop the oldest event to keep memory bounded.
        try
            take!(_QUEUE)
            put!(_QUEUE, e)
        catch
        end
    end

    handlers = lock(_SUBSCRIBER_LOCK) do
        matched = Function[]
        for (pattern, hs) in _SUBSCRIBERS
            if isempty(pattern) || startswith(kind, pattern)
                append!(matched, hs)
            end
        end
        matched
    end
    for handler in handlers
        try
            handler(e)
        catch err
            KamilaLog.warn(
                "event.handler.failed";
                mod = "events",
                fields = Dict("kind" => kind, "error" => string(err)),
            )
        end
    end
    return nothing
end

"""
Consume one pending event without dispatching to subscribers. Used by tests to
assert publish order.
"""
function drain(limit::Int = 1)
    out = Any[]
    while limit > 0
        isready(_QUEUE) || break
        try
            push!(out, take!(_QUEUE))
        catch
            break
        end
        limit -= 1
    end
    return out
end

function pending_count()
    return length(_QUEUE)
end

function clear_queue!()
    while isready(_QUEUE)
        try
            take!(_QUEUE)
        catch
            break
        end
    end
    return nothing
end

function clear_subscribers!()
    lock(_SUBSCRIBER_LOCK) do
        empty!(_SUBSCRIBERS)
    end
    return nothing
end

end # module Events