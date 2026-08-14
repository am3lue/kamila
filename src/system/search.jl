"""
Search — reliable, rate-limited web search with a swappable backend.

Replaces the fragile DDG HTML string-scraping `web_search` (02.4). The module
exposes `search(query; max_results)` returning `Vector{Dict(:title,:url,:snippet)}`
or `nothing` on failure (never a half-parsed page). Backends:

  - `"ddg-lite"` (default): DuckDuckGo lite endpoint, parsed structurally with a
    small HTML tag stripper instead of opaque class-string splitting.
  - `"custom"`: generic JSON endpoint from config (`~/.kamila_config.json`
    `search.backend`/`search.endpoint`/`search.api_key`), so users can point at
    a Brave/Serper/etc. endpoint without code changes.

All requests pass through a token bucket (1 req / 1.5 s, burst 5) and an
in-memory LRU cache (max 200, TTL 10 min) so agent loops don't hammer the
backend. Results are URL-hygiened (DDG `uddg=` redirects unwrapped) and snippet
capped at 300 chars.
"""

module Search

using HTTP
using JSON
using ..KamilaLog
using ..Errors

export search, configure, clear_cache, reset_rate_limit, _backend_name, _parse_ddg_lite

# ─── HTTP seam (swappable for tests) ───────────────────────
# Tests bind `_set_http_get`/`_set_http_post` to a canned responder so the
# module is fully testable offline; production defaults to the real `HTTP`.
const _HTTP_GET = Ref{Any}(nothing)
const _HTTP_POST = Ref{Any}(nothing)

function _set_http_get(f)
    _HTTP_GET[] = f
    return nothing
end

function _set_http_post(f)
    _HTTP_POST[] = f
    return nothing
end

function _http_get(url::String; headers = Dict(), readtimeout = 15, retry = false)
    hook = _HTTP_GET[]
    if hook === nothing
        return HTTP.get(url; headers = headers, readtimeout = readtimeout, retry = retry)
    end
    return hook(url; headers = headers, readtimeout = readtimeout, retry = retry)
end

function _http_post(url::String; headers = Dict(), body = "", readtimeout = 15)
    hook = _HTTP_POST[]
    if hook === nothing
        return HTTP.post(url; headers = headers, body = body, readtimeout = readtimeout)
    end
    return hook(url; headers = headers, body = body, readtimeout = readtimeout)
end

# ─── Config ────────────────────────────────────────────────

const _BACKEND = Ref{String}("ddg-lite")
const _CUSTOM_ENDPOINT = Ref{String}("")
const _CUSTOM_KEY = Ref{String}("")

"""
Read the `search` section of the config file (`KAMILA_CONFIG_FILE` or
`~/.kamila_config.json`) and apply it. Unknown keys are ignored; a missing
config keeps the defaults.
"""
function configure(config_file::String = _default_config_file())
    isfile(config_file) || return nothing
    try
        data = JSON.parsefile(config_file)
        search_cfg = get(data, "search", Dict())
        if haskey(search_cfg, "backend")
            _BACKEND[] = string(get(search_cfg, "backend", "ddg-lite"))
        end
        if haskey(search_cfg, "endpoint")
            _CUSTOM_ENDPOINT[] = string(get(search_cfg, "endpoint", ""))
        end
        # API key comes from the environment first (never persist secrets in
        # config/logs); config value is a fallback for local-only setups.
        _CUSTOM_KEY[] =
            get(ENV, "KAMILA_SEARCH_KEY", string(get(search_cfg, "api_key", "")))
        KamilaLog.info("search configured: backend=$(_BACKEND[])"; mod = "search")
    catch e
        KamilaLog.warn("search config unreadable: $e"; mod = "search")
    end
    return nothing
end

_default_config_file() =
    get(ENV, "KAMILA_CONFIG_FILE", joinpath(homedir(), ".kamila_config.json"))

_backend_name() = _BACKEND[]

# ─── Rate limiting (token bucket) ─────────────────────────

const _RATE_RATE = Ref{Float64}(1.0 / 1.5)   # 1 token / 1.5 s
const _RATE_BURST = Ref{Int}(5)
const _TOKENS = Ref{Float64}(5.0)
const _LAST_TICK = Ref{Float64}(time())
const _RATE_LOCK = ReentrantLock()

# Is a request allowed right now? Returns true and consumes a token, or false.
function _rate_allow()
    lock(_RATE_LOCK) do
        now = time()
        elapsed = now - _LAST_TICK[]
        _TOKENS[] = min(_TOKENS[] + elapsed * _RATE_RATE[], _RATE_BURST[])
        _LAST_TICK[] = now
        if _TOKENS[] >= 1.0
            _TOKENS[] -= 1.0
            return true
        end
        return false
    end
end

function reset_rate_limit()
    lock(_RATE_LOCK) do
        _TOKENS[] = _RATE_BURST[]
        _LAST_TICK[] = time()
    end
    return nothing
end

# ─── Cache (LRU, TTL 10 min, max 200) ─────────────────────

const _CACHE = Dict{String,Tuple{Float64,Any}}()
const _CACHE_LRU = String[]
const _CACHE_MAX = 200
const _CACHE_TTL = Ref{Float64}(600.0)
const _CACHE_LOCK = ReentrantLock()

function _cache_key(query::String, max_results::Int)
    return "$query\x1f$max_results"
end

function _cache_get(key::String)
    lock(_CACHE_LOCK) do
        hit = get(_CACHE, key, nothing)
        if hit === nothing
            return nothing
        end
        cached_at, value = hit
        if time() - cached_at > _CACHE_TTL[]
            delete!(_CACHE, key)
            filter!(!=(key), _CACHE_LRU)
            return nothing
        end
        # Promote to most-recently-used.
        filter!(!=(key), _CACHE_LRU)
        push!(_CACHE_LRU, key)
        return value
    end
end

function _cache_put(key::String, value)
    lock(_CACHE_LOCK) do
        if !haskey(_CACHE, key)
            push!(_CACHE_LRU, key)
            if length(_CACHE_LRU) > _CACHE_MAX
                oldest = popfirst!(_CACHE_LRU)
                delete!(_CACHE, oldest)
            end
        end
        _CACHE[key] = (time(), value)
    end
    return nothing
end

function clear_cache()
    lock(_CACHE_LOCK) do
        empty!(_CACHE)
        empty!(_CACHE_LRU)
    end
    return nothing
end

_cache_size() =
    lock(_CACHE_LOCK) do
        length(_CACHE)
    end

# ─── Public API ────────────────────────────────────────────

"""
Search the web for `query`. Returns `Vector{Dict{Symbol,Any}}` with `:title`,
`:url`, `:snippet` keys, or `nothing` on failure (rate-limited, timeout, or a
bot/redirect page — never a half-parsed result set).
"""
function search(query::String; max_results::Int = 5)
    isempty(strip(query)) && return nothing

    key = _cache_key(query, max_results)
    cached = _cache_get(key)
    if cached !== nothing
        KamilaLog.debug("search cache hit"; mod = "search", fields = Dict("query" => query))
        return cached
    end

    _rate_allow() || begin
        KamilaLog.warn("search rate limited"; mod = "search", fields = Dict("query" => query))
        return nothing
    end

    results =
        _backend_name() == "custom" ? _search_custom(query, max_results) :
        _search_ddg_lite(query, max_results)

    if results !== nothing && !isempty(results)
        _cache_put(key, results)
    end
    return results
end

# ─── DDG lite backend ──────────────────────────────────────

function _search_ddg_lite(query::String, max_results::Int)
    url = "https://lite.duckduckgo.com/lite/?q=" * HTTP.escapeuri(query)
    headers = [
        "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0",
        "Accept" => "text/html",
    ]
    try
        response = _http_get(url; headers = headers, readtimeout = 15, retry = false)
        body = String(response.body)
        if _is_bot_page(body)
            KamilaLog.warn(
                "search returned a bot/anomaly page (no result links)";
                mod = "search",
                fields = Dict("query" => query),
            )
            return nothing
        end
        return _parse_ddg_lite(body, max_results)
    catch e
        KamilaLog.warn(
            "search failed: $(Errors.error_string(e))";
            mod = "search",
            fields = Dict("query" => query),
        )
        return nothing
    end
end

# Is this a DDG bot-check / redirect / "anomaly" page rather than results?
_is_bot_page(body::String) =
    occursin(r"anomaly|bot|unusual|temporarily blocked|captcha"i, body) &&
    !occursin("rel=\"nofollow\"", body)

"""
Parse DuckDuckGo lite HTML into result dicts.

DDG lite markup is structural, not class-string dependent: every result is an
anchor `rel="nofollow" href="//duckduckgo.com/l/?uddg=..."` whose text is the
title and whose trailing cell text is the snippet. We walk the anchors in
document order, take title + cleaned URL from each, and read the snippet as the
plain text following the anchor up to the next link. A page with no `nofollow`
result links (bot page, empty page) yields `nothing`.
"""
function _parse_ddg_lite(body::String, max_results::Int)
    isempty(body) && return nothing

    results = Dict{Symbol,Any}[]
    seen = Set{String}()
    link_re = r"<a rel=\"nofollow\"[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"si

    for m in eachmatch(link_re, body)
        url = clean_url(m.captures[1])
        title = strip(strip_tags(m.captures[2]))
        (isempty(url) || isempty(title)) && continue
        url in seen && continue
        push!(seen, url)

        # Snippet = text after this anchor's close tag, up to the next link.
        seg_start = m.match.offset + ncodeunits(m.match)
        seg_end = findnext(r"<a[ >]", body, seg_start)
        if seg_end === nothing
            seg_end = lastindex(body)
        else
            seg_end = first(seg_end) - 1
        end
        snippet = seg_end >= seg_start ? strip(strip_tags(body[seg_start:seg_end])) : ""
        if length(snippet) > 300
            snippet = snippet[1:300] * "…"
        end

        push!(results, Dict{Symbol,Any}(:title => title, :url => url, :snippet => snippet))
        length(results) >= max_results && break
    end

    isempty(results) && return nothing
    return results
end

# Strip HTML tags to text, preserving a little whitespace between block elements.
function strip_tags(html::AbstractString)
    text = replace(html, r"<script[^>]*>.*?</script>"s => " ")
    text = replace(text, r"<style[^>]*>.*?</style>"s => " ")
    text = replace(text, r"<br[^>]*>|<p[^>]*>|</p>|</tr>|</td>|<div[^>]*>|</div>"i => " ")
    text = replace(text, r"<[^>]+>" => " ")
    text = replace(text, r"&amp;" => "&")
    text = replace(text, r"&lt;" => "<")
    text = replace(text, r"&gt;" => ">")
    text = replace(text, "&quot;" => "\"")
    text = replace(text, "&#34;" => "\"")
    text = replace(text, r"&#39;|&apos;" => "'")
    text = replace(text, r"&nbsp;" => " ")
    text = replace(text, r"\s+" => " ")
    return strip(text)
end

"""
Unwrap DDG redirect links (`//duckduckgo.com/l/?uddg=<url>`) to the destination,
and drop tracking query params. Returns "" if the URL can't be resolved.
"""
function clean_url(raw::AbstractString)
    url = String(raw)
    # DDG lite wraps external results in //duckduckgo.com/l/?uddg=<dest>
    m = match(r"uddg=([^&]+)", url)
    if m !== nothing
        try
            url = HTTP.unescapeuri(m.captures[1])
        catch
        end
    end
    # Allow http(s) only.
    startswith(url, "http://") || startswith(url, "https://") || return ""
    # Drop obvious tracking params.
    url = replace(url, r"[?&](utm_[a-z]+|fbclid|gclid|ref)=[^&#]*"i => "")
    url = replace(url, r"&{2,}" => "&")
    return url
end

# ─── Custom backend ────────────────────────────────────────

"""
Query a generic JSON search endpoint (e.g. Brave/Serper style). The response is
expected to contain an array of results with `title`/`url`/`snippet`-ish keys,
either at the top level or under a common container key.
"""
function _search_custom(query::String, max_results::Int)
    isempty(_CUSTOM_ENDPOINT[]) && begin
        KamilaLog.warn("search backend=custom but no endpoint configured"; mod = "search")
        return nothing
    end
    headers = ["Content-Type" => "application/json"]
    if !isempty(_CUSTOM_KEY[])
        headers = vcat(headers, ["X-API-Key" => _CUSTOM_KEY[]])
    end
    payload = JSON.json(Dict("query" => query, "count" => max_results))
    try
        response = _http_post(
            _CUSTOM_ENDPOINT[];
            headers = headers,
            body = payload,
            readtimeout = 15,
        )
        data = JSON.parse(String(response.body))
        items = _extract_result_items(data)
        results = Dict{Symbol,Any}[]
        for item in items
            title = string(get(item, "title", get(item, "name", "")))
            url = clean_url(string(get(item, "url", get(item, "link", ""))))
            snippet = string(
                get(item, "snippet", get(item, "description", get(item, "content", ""))),
            )
            (isempty(title) || isempty(url)) && continue
            if length(snippet) > 300
                snippet = snippet[1:300] * "…"
            end
            push!(
                results,
                Dict{Symbol,Any}(:title => title, :url => url, :snippet => snippet),
            )
            length(results) >= max_results && break
        end
        isempty(results) && return nothing
        return results
    catch e
        KamilaLog.warn(
            "custom search failed: $(Errors.error_string(e))";
            mod = "search",
            fields = Dict("query" => query),
        )
        return nothing
    end
end

function _extract_result_items(data)
    if data isa AbstractVector
        return data
    elseif data isa AbstractDict
        for key in ("results", "organic", "items", "web", "data")
            if haskey(data, key)
                val = data[key]
                if val isa AbstractVector
                    return val
                elseif val isa AbstractDict && haskey(val, "results")
                    return val["results"]
                end
            end
        end
    end
    return Any[]
end

end # module Search
