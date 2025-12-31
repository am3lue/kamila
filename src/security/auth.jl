"""
Authentication Module for Kamila
Handles user authentication and password management
"""

module Auth

using SHA
using Random
using JSON
using Dates
using ..Kamila

export authenticate_user, setup_password, change_password, verify_password, reset_auth

const CONFIG_FILE = Kamila.CONFIG_FILE
const DEFAULT_PASSWORD = "kamila123"

"""
Check if authentication is already configured
"""
function is_auth_configured()
    return isfile(CONFIG_FILE)
end

"""
Setup initial password
"""
function setup_password()
    println("🔐 Setting up Kamila authentication...")
    println("Please create a secure password for Kamila access.")
    println("Choose a strong password (minimum 8 characters recommended)")
    println()
    
    while true
        print("Enter new password: ")
        password1 = readline(stdin)
        
        if length(password1) < 4
            println("⚠️  Password too short. Please use at least 4 characters.")
            continue
        end
        
        print("Confirm password: ")
        password2 = readline(stdin)
        
        if password1 != password2
            println("❌ Passwords do not match. Please try again.")
            continue
        end
        
        # Save the hashed password
        return save_password_hash(password1)
    end
end

"""
Save password hash to config file
"""
function save_password_hash(password::String)
    try
        # Generate salt and hash password
        salt = bytes2hex(rand(UInt8, 16))
        password_hash = bytes2hex(sha256(password * salt))
        
        config = Dict(
            "password_hash" => password_hash,
            "salt" => salt,
            "created_date" => string(now()),
            "last_access" => "",
            "failed_attempts" => 0,
            "locked" => false
        )
        
        write(CONFIG_FILE, JSON.json(config, 2))
        println("✅ Password successfully configured!")
        return true
    catch e
        println("❌ Error saving password: $e")
        return false
    end
end

"""
Authenticate user with password
"""
function authenticate_user(;max_attempts::Int=3)
    # If no config exists, use default password setup
    if !is_auth_configured()
        println("🔧 First time setup required.")
        return setup_password()
    end
    
    # Load config
    config = load_auth_config()
    
    # Check if account is locked
    if get(config, "locked", false)
        println("❌ Account is locked due to too many failed attempts.")
        println("Please contact administrator or wait before retrying.")
        return false
    end
    
    attempts = 0
    while attempts < max_attempts
        print("Enter password: ")
        password = readline(stdin)
        
        if verify_password(password)
            # Update last access
            config["last_access"] = string(now())
            config["failed_attempts"] = 0
            save_auth_config(config)
            
            println("✅ Authentication successful!")
            return true
        else
            attempts += 1
            config["failed_attempts"] = attempts
            
            if attempts >= max_attempts
                # Lock account after max attempts
                config["locked"] = true
                save_auth_config(config)
                println("❌ Too many failed attempts. Account locked.")
                return false
            else
                remaining = max_attempts - attempts
                println("❌ Incorrect password. $remaining attempts remaining.")
            end
        end
    end
    
    return false
end

"""
Verify password against stored hash
"""
function verify_password(password::String)
    try
        config = load_auth_config()
        stored_hash = get(config, "password_hash", "")
        salt = get(config, "salt", "")
        
        if isempty(stored_hash) || isempty(salt)
            return false
        end
        
        # Hash the provided password with the same salt
        computed_hash = bytes2hex(sha256(password * salt))
        
        return computed_hash == stored_hash
    catch
        return false
    end
end

"""
Change existing password
"""
function change_password()
    if !is_auth_configured()
        println("❌ No password is currently set. Please run setup first.")
        return false
    end
    
    print("Enter current password: ")
    current_password = readline(stdin)
    
    if !verify_password(current_password)
        println("❌ Current password is incorrect.")
        return false
    end
    
    println("Enter your new password:")
    while true
        print("New password: ")
        new_password1 = readline(stdin)
        
        if length(new_password1) < 4
            println("⚠️  Password too short. Please use at least 4 characters.")
            continue
        end
        
        print("Confirm new password: ")
        new_password2 = readline(stdin)
        
        if new_password1 != new_password2
            println("❌ Passwords do not match. Please try again.")
            continue
        end
        
        # Save the new password
        if save_password_hash(new_password1)
            println("✅ Password successfully changed!")
            return true
        else
            return false
        end
    end
end

"""
Load authentication configuration
"""
function load_auth_config()
    try
        if !isfile(CONFIG_FILE)
            return Dict()
        end
        
        content = read(CONFIG_FILE, String)
        return JSON.parse(content)
    catch
        return Dict()
    end
end

"""
Save authentication configuration
"""
function save_auth_config(config::AbstractDict)
    try
        write(CONFIG_FILE, JSON.json(config, 2))
        return true
    catch
        return false
    end
end

"""
Reset authentication (dangerous - use with caution)
"""
function reset_auth()
    if isfile(CONFIG_FILE)
        try
            rm(CONFIG_FILE)
            println("✅ Authentication configuration reset.")
            println("Next login will require setting up a new password.")
            return true
        catch e
            println("❌ Error resetting authentication: $e")
            return false
        end
    else
        println("ℹ️  No authentication configuration found to reset.")
        return true
    end
end

"""
Get authentication status
"""
function get_auth_status()
    if !is_auth_configured()
        return Dict(
            "configured" => false,
            "locked" => false,
            "failed_attempts" => 0,
            "last_access" => "never"
        )
    end
    
    config = load_auth_config()
    return Dict(
        "configured" => true,
        "locked" => get(config, "locked", false),
        "failed_attempts" => get(config, "failed_attempts", 0),
        "last_access" => get(config, "last_access", "never"),
        "created_date" => get(config, "created_date", "unknown")
    )
end

"""
Simple password prompt (legacy compatibility)
"""
function simple_auth_prompt()
    print("Enter password: ")
    password = readline(stdin)
    return password == DEFAULT_PASSWORD
end

"""
Unlock account (admin function)
"""
function unlock_account()
    if !is_auth_configured()
        println("❌ No authentication configuration found.")
        return false
    end
    
    config = load_auth_config()
    config["locked"] = false
    config["failed_attempts"] = 0
    
    if save_auth_config(config)
        println("✅ Account unlocked successfully.")
        return true
    else
        println("❌ Failed to unlock account.")
        return false
    end
end

end # module
