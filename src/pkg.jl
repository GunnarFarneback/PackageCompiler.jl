using Pkg
using Pkg: TOML
using Pkg: Operations, Types, API
using UUIDs

#=
genfile & create_project_from_require have been taken from the PR
https://github.com/JuliaLang/PkgDev.jl/pull/144
which was created by https://github.com/KristofferC

THIS IS JUST A TEMPORARY SOLUTION FOR PACKAGES WITHOUT A TOML AND WILL GET MOVED OUT!
=#

function packages_from_require(reqfile::String)
    ctx = Pkg.Types.Context()
    pkgs = Types.PackageSpec[]
    compatibility = Pair{String, String}[]
    for r in Pkg.Pkg2.Reqs.read(reqfile)
        r isa Pkg.Pkg2.Reqs.Requirement || continue
        r.package == "julia" && continue
        push!(pkgs, Types.PackageSpec(r.package))
        intervals = r.versions.intervals
        if length(intervals) != 1
            @warn "Project.toml creator cannot handle multiple requirements for $(r.package), ignoring"
        else
            l = intervals[1].lower
            h = intervals[1].upper
            if l != v"0.0.0-"
                # no upper bound
                if h == typemax(VersionNumber)
                    push!(compatibility, r.package => string(">=", VersionNumber(l.major, l.minor, l.patch)))
                else # assume semver
                    push!(compatibility, r.package => string(">=", VersionNumber(l.major, l.minor, l.patch), ", ",
                                                             "<", VersionNumber(h.major, h.minor, h.patch)))
                end
            end
        end
    end
    Operations.registry_resolve!(ctx.env, pkgs)
    Operations.ensure_resolved(ctx.env, pkgs)
    pkgs
end

function isinstalled(pkg::Types.PackageSpec, installed = Pkg.installed())
    root_path(pkg) === nothing && return false
    return haskey(installed, pkg.name)
end

function only_installed(pkgs::Vector{Types.PackageSpec})
    installed = Pkg.installed()
    filter(p-> isinstalled(p, installed), pkgs)
end
function not_installed(pkgs::Vector{Types.PackageSpec})
    installed = Pkg.installed()
    filter(p-> !isinstalled(p, installed), pkgs)
end

function root_path(pkg::Types.PackageSpec)
    path = Base.locate_package(Base.PkgId(pkg.uuid, pkg.name))
    path === nothing && return nothing
    return abspath(joinpath(dirname(path)), "..")
end

function test_dependencies!(pkgs::Vector{Types.PackageSpec}, result = Dict{Base.UUID, Types.PackageSpec}())
    for pkg in pkgs
        test_dependencies!(root_path(pkg), result)
    end
    return result
end

function test_dependencies!(pkg_root, result = Dict{Base.UUID, Types.PackageSpec}())
    testreq = joinpath(pkg_root, "test", "REQUIRE")
    toml = joinpath(pkg_root, "Project.toml")
    if isfile(toml)
        pkgs = get(TOML.parsefile(toml), "extras", nothing)
        if pkgs !== nothing
            merge!(result, Dict((Base.UUID(uuid) => PackageSpec(name = n, uuid = uuid) for (n, uuid) in pkgs)))
        end
    end
    if isfile(testreq)
        deps = packages_from_require(testreq)
        merge!(result, Dict((d.uuid => d for d in deps)))
    end
    result
end
function test_dependencies(pkgspecs::Vector{Pkg.Types.PackageSpec})
    result = Dict{Base.UUID, Types.PackageSpec}()
    for pkg in pkgspecs
        path = Base.locate_package(Base.PkgId(pkg.uuid, pkg.name))
        test_dependencies!(joinpath(dirname(path), ".."), result)
    end
    return Set(values(result))
end

get_snoopfile(pkg::Types.PackageSpec) = get_snoopfile(root_path(pkg))

const relative_snoop_locations = (
    "snoopfile.jl",
    joinpath("snoop", "snoopfile.jl"),
    joinpath("precompile", "snoopfile.jl"),
    joinpath("test", "snoopfile.jl"),
    joinpath("test", "runtests.jl"),
)

"""
    get_snoopfile(pkg_root::String) -> snoopfile.jl

Get's the snoopfile for a package in the path `pkg_root`.
"""
function get_snoopfile(pkg_root::String)
    paths = joinpath.(pkg_root, relative_snoop_locations)
    idx = findfirst(isfile, paths)
    idx === nothing && error("No snoopfile or testfile found for package $pkg_root")
    return paths[idx]
end

"""
    snoop2root(snoopfile) -> pkg_root
Given a path to a snoopfile, this function returns the package root.
If the file isn't of a known format it will return nothing.
reverse of get_snoopfile(pkg_root)
"""
function snoop2root(path)
    npath = normpath(path)
    for path_ends in relative_snoop_locations
        endswith(npath, path_ends) && return replace(npath, path_ends => "")
    end
    return nothing
end

function resolve_package(ctx, pkg::String)
    manifest = ctx.env.manifest
    for (uuid, pkgspec) in manifest
        if pkgspec.name == pkg
            return Base.PkgId(uuid, pkg)
        end
    end
    return nothing
end

function resolve_packages(ctx, pkgs::Vector{String})
    manifest = ctx.env.manifest
    result = Set{Pkg.Types.PackageSpec}()
    pkgs_copy = copy(pkgs)
    for (uuid, pkgspec) in manifest
        idx = findfirst(x-> string(pkgspec.name) === x, pkgs_copy)
        if idx !== nothing
            push!(result, PackageSpec(name = pkgs_copy[idx], uuid = uuid))
            splice!(pkgs_copy, idx)
        end
    end
    if !isempty(pkgs_copy)
        error("Could not resolve the following packages: $(pkgs_copy)")
    end
    return result
end


function resolve_packages(ctx, pkgs::Set{Base.UUID})
    manifest = ctx.env.manifest
    result = Set{Pkg.Types.PackageSpec}()
    pkgs_copy = copy(pkgs)
    for (uuid, pkgspec) in manifest
        if uuid in pkgs
            push!(result, PackageSpec(name = pkgspec.name, uuid = uuid))
            delete!(pkgs_copy, uuid)
        end
    end
    if !isempty(pkgs_copy)
        error("Could not resolve the following packages: $(pkgs_copy)")
    end
    return result
end

get_deps(manifest, uuid) = manifest[uuid].deps

function topo_deps(manifest, uuids::Vector{UUID})
    result = Dict{UUID, Any}()
    for uuid in uuids
        get!(result, uuid) do
            topo_deps(manifest, uuid)
        end
    end
    return result
end

function topo_deps(manifest, uuid::UUID)
    result = Dict{UUID, Any}()
    for (name, uuid) in get_deps(manifest, uuid)
        get!(result, uuid) do
            topo_deps(manifest, uuid)
        end
    end
    result
end

function flatten_deps(deps, result = Set{UUID}())
    for (uuid, depdeps) in deps
        push!(result, uuid)
        flatten_deps(depdeps, result)
    end
    result
end

function flat_deps(ctx::Pkg.Types.Context, pkg_names::AbstractVector{String})
    manifest = ctx.env.manifest
    return flat_deps(ctx, resolve_packages(ctx, pkg_names))
end

function flat_deps(ctx::Pkg.Types.Context, pkgs::Set{Pkg.Types.PackageSpec})
    isempty(pkgs) && return Set{Pkg.Types.PackageSpec}()
    manifest = ctx.env.manifest
    deps = topo_deps(manifest, getfield.(pkgs, :uuid))
    flat = flatten_deps(deps)
    return resolve_packages(ctx, flat)
end
