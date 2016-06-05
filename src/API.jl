# This file contains the API that users interact with.  Everything in here should
# depend only on `brew()` calls.

"""
brew(cmd::Cmd; no_stderr=false, no_stdout=false, verbose=false, force=false, quiet=false)

Run command `cmd` using the configured brew binary, optionally suppressing
stdout and stderr, and providing flags such as `--verbose` to the brew binary.
"""
function brew(cmd::Cmd; no_stderr=false, no_stdout=false, verbose::Bool=false, force::Bool=false, quiet::Bool=false)
    @compat cmd = add_flags(`$brew_exe $cmd`, Dict(`--verbose` => verbose, `--force` => force, `--quiet` => quiet))

    if no_stderr
        @compat cmd = pipeline(cmd, stderr=DevNull)
    end
    if no_stdout
        @compat cmd = pipeline(cmd, stdout=DevNull)
    end
    return run(cmd)
end

"""
brewchomp(cmd::Cmd; no_stderr=false, no_stdout=false, verbose=false, force=false, quiet=false))

Run command `cmd` using the configured brew binary, optionally suppressing
stdout and stderr, and providing flags such as `--verbose` to the brew binary.

This function uses `readchomp()`, as opposed to `brew()` which uses `run()`
"""
function brewchomp(cmd::Cmd; no_stderr=false, no_stdout=false, verbose::Bool=false, force::Bool=false, quiet::Bool=false)
    @compat cmd = add_flags(`$brew_exe $cmd`, Dict(`--verbose` => verbose, `--force` => force, `--quiet` => quiet))

    if no_stderr
        @compat cmd = pipeline(cmd, stderr=DevNull)
    end
    if no_stdout
        @compat cmd = pipeline(cmd, stdout=DevNull)
    end
    return readchomp(cmd)
end

"""
update()

Runs `brew update` to update Homebrew itself and all taps.  Then runs `upgrade()`
to upgrade all formulae that have fallen out of date.
"""
function update()
    # Just run `brew update`
    brew(`update`)

    # Finally, upgrade outdated packages.
    upgrade()
end

"""
prefix()

Returns `brew_prefix`, the location where all Homebrew files are stored.
"""
function prefix()
    return brew_prefix
end

"""
prefix(name::AbstractString)

Returns the prefix for a particular package's latest installed version.
"""
function prefix(name::AbstractString)
    cellar_path = joinpath(brew_prefix, "Cellar", name)
    version_str = info(name).version_str
    return joinpath(brew_prefix, "Cellar", name, version_str)
end

"""
prefix(pkg::BrewPkg)

Returns the prefix for a particular package's latest installed version.
"""
function prefix(pkg::BrewPkg)
    prefix(pkg.name)
end

"""
list()

Returns a list of all installed packages as a `Vector{BrewPkg}`
"""
function list()
    brew_list = brewchomp(`list --versions`)
    if !isempty(brew_list)
        pkgs = BrewPkg[]
        for f in split(brew_list,"\n")
            name = split(f, " ")[1]
            vers = make_version(name, split(f, " ")[2])
            vers_str = split(f, " ")[2]
            push!(pkgs, BrewPkg(name, vers, vers_str, false))
        end
        return pkgs
    else
        BrewPkg[]
    end
end

"""
outdated()

Returns a list of all installed packages that are out of date as a `Vector{BrewPkg}`
"""
function outdated()
    json_str = brewchomp(`outdated --json=v1`)
    if isempty(json_str)
        return BrewPkg[]
    end
    brew_outdated = JSON.parse(json_str)

    outdated_pkgs = BrewPkg[info(pkg["name"]) for pkg in brew_outdated]
    return outdated_pkgs
end

"""
refresh(;verbose=false)

Forcibly remove all packages and add them again.  This should only be used to
fix a broken installation, normal operation should never need to use this.
"""
function refresh!(;verbose=false)
    pkg_list = list()
    for pkg in pkg_list
        rm(pkg,verbose=verbose)
    end
    for pkg in pkg_list
        add(pkg,verbose=verbose)
    end
end

"""
upgrade()

Iterate over all packages returned from `outdated()`, removing the old version
and adding a new one.  Note that we do not simply call `brew upgrade` here, as
we have special logic inside of `add()` to install from our tap before trying to
install from mainline Homebrew.
"""
function upgrade()
    # We have to manually upgrade each package, as `brew upgrade` will pull from mxcl/master
    for pkg in outdated()
        rm(pkg)
        add(pkg)
    end
end

const json_cache = Dict{String,Dict{AbstractString,Any}}()
"""
json(names::Vector{AbstractString})

For each package name in `names`, return the full JSON object for `name`, the
result of `brew info --json=v1 \$name`, stored in a dictionary keyed by the names
passed into this function. If `brew info` fails, throws an error. If `brew info`
returns an empty object "[]", that object is represented by an empty dictionary.

Note that running `brew info --json=v1` is somewhat expensive, so we cache the
results in a global dictionary, and batching larger requests with this function
similarly increases performance.
"""
function json{T<:AbstractString}(names::Vector{T})
    # First, normalize all names
    names = String[normalize_name(n) for n in names]

    # This is the dictionary of responses we'll return
    objs = Dict{String,Dict{AbstractString,Any}}()

    # Build list of names we have to ask for, eschewing asking for caching when we can
    ask_names = String[]
    for name in names
        if haskey(json_cache, name)
            objs[name] = json_cache[name]
        else
            push!(ask_names, name)
        end
    end

    # Now ask for all these names if we have any
    if !isempty(ask_names)
        try
            jdata = JSON.parse(brewchomp(Cmd(String["info", "--json=v1", ask_names...])))
            for idx in 1:length(jdata)
                json_cache[ask_names[idx]] = jdata[idx]
                objs[ask_names[idx]] = jdata[idx]
            end
        catch
            throw(ArgumentError("`brew info` failed for $(name)!"))
        end
    end

    # Return these hard-won objects
    return objs
end

"""
json(name::AbstractString)

Return the full JSON object for `name`, the result of `brew info --json=v1 \$name`.
If `brew info` fails, throws an error.  If `brew info` returns an empty object,
(e.g. "[]"), this returns an empty Dict.

Note that running `brew info --json=v1` is somewhat expensive, so we cache the
results in a global dictionary, and batching larger requests with this function
similarly increases performance.
"""
function json(name::AbstractString)
    return json([name])[normalize_name(name)]
end

"""
json(pkg::BrewPkg)

Return the full JSON object for `pkg`, the result of `brew info --json=v1 \$pkg`.
If `brew info` fails, throws an error.  If `brew info` returns an empty object,
(e.g. "[]"), this returns an empty Dict.

Note that running `brew info --json=v1` is somewhat expensive, so we cache the
results in a global dictionary, and batching larger requests with this function
similarly increases performance.
"""
function json(pkg::BrewPkg)
    return json([pkg.name])[normalize_name(pkg.name)]
end

"""
info(names::Vector{String})

For each name in `names`, returns information about that particular package name
as a BrewPkg.  This is our batched `String` -> `BrewPkg` converter.
"""
function info{T<:AbstractString}(names::Vector{T})
    # Get the JSON representations of all of these packages
    objs = json(names)

    infos = BrewPkg[]
    for name in names
        obj = objs[normalize_name(name)]

        # First, get name and version
        obj_name = obj["name"]
        version = make_version(obj_name, obj["versions"]["stable"])
        version_str = obj["versions"]["stable"]

        # Manually append the revision to the end of the version_str, as brew is wont to do
        if obj["revision"] > 0
            version_str *= "_$(obj["revision"])"
        end
        bottled = obj["versions"]["bottle"]

        # If we actually have a keg, return whether it was poured
        if !isempty(obj["installed"])
            bottled = obj["installed"][1]["poured_from_bottle"]
        end

        # Push that BrewPkg onto our infos object
        push!(infos, BrewPkg(obj_name, version, version_str, bottled))
    end

    # Return the list of infos
    return infos
end

"""
info(name::AbstractString)

Returns information about a particular package name as a BrewPkg.  This is our
basic `String` -> `BrewPkg` converter.
"""
function info(name::AbstractString)
    return info([name])[1]
end

"""
deps(name::AbstractString)

Return a list of all direct dependencies of `name` as a `Vector{BrewPkg}`
"""
function deps(name::AbstractString)
    obj = json(name)

    # Iterate over all dependencies, removing optional dependencies
    dependencies = String[dep for dep in obj["dependencies"]]
    dependencies = filter(x -> !(x in obj["optional_dependencies"]), dependencies)
    return info(dependencies)
end

"""
deps(pkg::BrewPkg)

Return a list of all direct dependencies of `pkg` as a `Vector{BrewPkg}`
"""
function deps(pkg::BrewPkg)
    return deps(pkg.name)
end

"""
deps_tree(name::AbstractString)

Return a dictionary mapping every dependency (both direct and indirect) of `name`
to a `Vector{BrewPkg}` of all of its dependencies.  Used in `deps_sorted()`.
"""
function deps_tree(name::AbstractString)
    # First, get all the knowledge we need about dependencies
    deptree = Dict{String,Vector{BrewPkg}}()

    pending_deps = deps(name)
    completed_deps = Set(String[])
    while !isempty(pending_deps)
        # Temporarily move pending_deps over to curr_pending_deps
        curr_pending_deps = pending_deps
        pending_deps = BrewPkg[]

        # Iterate over these currently pending deps, adding new ones to pending_deps
        for pkg in curr_pending_deps
            deptree[pkg.name] = deps(pkg)
            push!(completed_deps, pkg.name)
            for dpkg in deptree[pkg.name]
                if !(dpkg.name in completed_deps)
                    push!(pending_deps, dpkg)
                end
            end
        end
    end

    return deptree
end

"""
deps_tree(pkg::BrewPkg)

Return a dictionary mapping every dependency (both direct and indirect) of `pkg`
to a `Vector{BrewPkg}` of all of its dependencies.  Used in `deps_sorted()`.
"""
function deps_tree(pkg::BrewPkg)
    return deps_tree(pkg.name)
end

"""
insert_after_dependencies(tree::Dict, sorted_deps::Vector{BrewPkg}, name::String)

Given a mapping from names to dependencies in `tree`, and a list of sorted
dependencies in `sorted_deps`, insert a new dependency `name` into `sorted_deps`
after all dependencies of `name`.  If a dependency of `name` is not already in
`sorted_deps`, then recursively add that dependency as well.
"""
function insert_after_dependencies(tree::Dict, sorted_deps::Vector{BrewPkg}, name::AbstractString)
    # First off, are we already in sorted_deps?  If so, back out!
    self_idx = findfirst(x -> (x.name == name), sorted_deps)
    if self_idx != 0
        return self_idx
    end

    # This is the index at which we will insert ourselves
    insert_idx = 1
    # Iterate over all dependencies
    for dpkg in tree[name]
        # Is this dependency already in the sorted_deps?
        idx = findfirst(x -> (x.name == dpkg.name), sorted_deps)

        # If the dependency is not already in this list, then recurse into it!
        if idx == 0
            idx = insert_after_dependencies(tree, sorted_deps, dpkg.name)
        end

        # Otherwise, update insert_idx
        insert_idx = max(insert_idx, idx + 1)
    end

    # Finally, insert ourselves
    insert!(sorted_deps, insert_idx, info(name))
    return insert_idx
end

"""
deps_sorted(name::AbstractString)

Return a sorted `Vector{BrewPkg}` of all dependencies (direct and indirect) such
that each entry in the list appears after all of its own dependencies
"""
function deps_sorted(name::AbstractString)
    tree = deps_tree(name)
    sorted_deps = BrewPkg[]

    # For each package in the tree, insert it only after all of its dependencies
    # Just for aesthetic purposes, sort the keys by the number of dependencies
    # they have first, so that packages with few deps end up on top
    for name in sort(collect(keys(tree)), by=k-> length(tree[k]))
        insert_after_dependencies(tree, sorted_deps, name)
    end

    return sorted_deps
end

"""
deps_sorted(name::AbstractString)

Return a sorted `Vector{BrewPkg}` of all dependencies (direct and indirect) such
that each entry in the list appears after all of its own dependencies
"""
function deps_sorted(pkg::BrewPkg)
    return deps_sorted(pkg.name)
end

"""
add(name::AbstractString; verbose=false)

Install a package and all dependencies, using bottles only, unlinking any
previous versions if necessary, and linking the new ones in place.
"""
function add(name::AbstractString; verbose=false)
    name = normalize_name(name)

    # Install this package and all dependencies, in dependency order
    for dname in deps_sorted(name)
        install_and_link(dname.name; verbose=verbose)
    end

    # Finally, install this package itself
    install_and_link(name; verbose=verbose)
end

"""
add(pkg::BrewPkg; verbose=false)

Install a package and all dependencies, using bottles only, unlinking any
previous versions if necessary, and linking the new ones in place.
"""
function add(pkg::BrewPkg; verbose=false)
    add(pkg.name, verbose=verbose)
end


"""
install_and_link(name::AbstractString; verbose=false)

Unlinks, installs, and links package `name`.  Used by `add()`.  Don't call
manually unless you really know what you're doing, as this doesn't deal with
dependencies, and so can trigger compilation when you don't want it to.
"""
function install_and_link(name::AbstractString; verbose::Bool=false)
    if linked(name)
        unlink(name; verbose=verbose)
    end

    # Install dependency and link it
    brew(`install --force-bottle $name`; verbose=verbose)
    link(name; verbose=verbose)
end

"""
install_and_link(pkg::BrewPkg; verbose=false)

Unlinks, installs, and links package `name`.  Used by `add()`.  Don't call
manually unless you really know what you're doing, as this doesn't deal with
dependencies, and so can trigger compilation when you don't want it to.
"""
function install_and_link(pkg::BrewPkg; verbose::Bool=false)
    return install_and_link(pkg.name; verbose=verbose)
end


"""
postinstall(name::AbstractString; verbose=false)

Runs `brew postinstall` against package `name`, useful for debugging complicated
formulae when a bottle doesn't install right and you want to re-run postinstall.
"""
function postinstall(pkg::AbstractString; verbose::Bool=false)
    brew(`postinstall $pkg`, verbose=verbose)
end

"""
postinstall(pkg::BrewPkg; verbose=false)

Runs `brew postinstall` against package `pkg`, useful for debugging complicated
formulae when a bottle doesn't install right and you want to re-run postinstall.
"""
function postinstall(pkg::BrewPkg; verbose::Bool=false)
    postinstall(pkg.name, verbose=verbose)
end


"""
link(name::AbstractString; verbose=false, force=true)

Link package `name` into the global namespace, uses `--force` if `force == true`
"""
function link(name::AbstractString; verbose::Bool=false, force::Bool=true)
    brew(`link $name`, no_stdout=true, verbose=verbose, force=force)
end

"""
link(pkg::BrewPkg; verbose=false, force=true)

Link package `pkg` into the global namespace, uses `--force` if `force == true`
"""
function link(pkg::BrewPkg; verbose::Bool=false, force::Bool=true)
    return link(pkg.name; force=force, verbose=verbose)
end


"""
unlink(name::AbstractString; verbose=false, quiet=true)

Unlink package `name` from the global namespace, uses `--quiet` if `quiet == true`
"""
function unlink(name::AbstractString; verbose::Bool=false, quiet::Bool=true)
    brew(`unlink $name`; verbose=verbose, quiet=quiet)
end

"""
unlink(pkg::BrewPkg; verbose=false, quiet=true)

Unlink package `pkg` from the global namespace, uses `--quiet` if `quiet == true`
"""
function unlink(pkg::BrewPkg; verbose::Bool=false, quiet::Bool=true)
    return unlink(pkg.name; verbose=verbose, quiet=quiet)
end


"""
rm(name::AbstractString; verbose=false, force=true)

Remove package `name`, use `--force` if `force` == `true`
"""
function rm(pkg::AbstractString; verbose::Bool=false, force=true)
    brew(`rm $pkg`; verbose=verbose, force=force)
end

"""
rm(pkg::BrewPkg; verbose=false, force=true)

Remove package `name`, use `--force` if `force` == `true`
"""
function rm(pkg::BrewPkg; verbose::Bool=false, force=true)
    return rm(pkg.name; verbose=verbose, force=force)
end


"""
tap(tap_name::AbstractString; verbose=false)

Runs `brew tap \$tap_name` if the tap does not already exist
"""
function tap(tap_name::AbstractString; verbose::Bool=false)
    if !tap_exists(tap_name)
        brew(`tap $tap_name`; verbose=verbose)
    end
end
