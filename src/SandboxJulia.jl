module SandboxJulia

using LazyArtifacts, Sandbox
export run_sandboxed_julia

lazy_artifact(x) = @artifact_str(x)

const rootfs_lock = ReentrantLock()
const rootfs_cache = Dict()
function prepare_rootfs(distro="debian"; uid=1000, user="pkgeval", gid=1000, group="pkgeval", home="/home/$user")
    lock(rootfs_lock) do
        get!(rootfs_cache, (distro, uid, user, gid, group, home)) do
            base = lazy_artifact(distro)

            # a bare rootfs isn't usable out-of-the-box
            derived = mktempdir()
            cp(base, derived; force=true)

            # add a user and group
            chmod(joinpath(derived, "etc/passwd"), 0o644)
            open(joinpath(derived, "etc/passwd"), "a") do io
                println(io, "$user:x:$uid:$gid::$home:/bin/bash")
            end
            chmod(joinpath(derived, "etc/group"), 0o644)
            open(joinpath(derived, "etc/group"), "a") do io
                println(io, "$group:x:$gid:")
            end
            chmod(joinpath(derived, "etc/shadow"), 0o640)
            open(joinpath(derived, "etc/shadow"), "a") do io
                println(io, "$user:*:::::::")
            end

            # replace resolv.conf
            rm(joinpath(derived, "etc/resolv.conf"); force=true)
            write(joinpath(derived, "etc/resolv.conf"), read("/etc/resolv.conf"))

            return (path=derived, uid, user, gid, group, home)
        end
    end
end

"""
    run_sandboxed_julia(install::String, args=``; env=Dict(), mounts=Dict(),
                        wait=true, stdin=stdin, stdout=stdout, stderr=stderr,
                        install_dir="/opt/julia", kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The argument `wait`
determines if the process will be waited on. Streams can be connected using the `stdin`,
`stdout` and `sterr` arguments. Returns a `Process` object.

Further customization is possible using the `env` arg, to set environment variables, and the
`mounts` argument to mount additional directories. With `install_dir`, the directory where
Julia is installed can be chosen.
"""
function run_sandboxed_julia(install::String, args=``; wait=true,
                             mounts::Dict{String,String}=Dict{String,String}(),
                             kwargs...)
    config, cmd = runner_sandboxed_julia(install, args; kwargs...)

    # XXX: even when preferred_executor() returns UnprivilegedUserNamespacesExecutor,
    #      sometimes a stray sudo happens at run time? no idea how.
    exe_typ = UnprivilegedUserNamespacesExecutor
    exe = exe_typ()
    proc = Base.run(exe, config, cmd; wait)

    # TODO: introduce a --stats flag that has the sandbox trace and report on CPU, network, ... usage

    if wait
        cleanup(exe)
    else
        @async begin
            try
                Base.wait(proc)
                cleanup(exe)
            catch err
                @error "Unexpected error while cleaning up process" exception=(err, catch_backtrace())
            end
        end
    end

    return proc
end

# global Xvfb process for use by all containers
const xvfb_lock = ReentrantLock()
const xvfb_proc = Ref{Union{Base.Process,Nothing}}(nothing)


function installed_julia_dir(jp)
    jp_contents = readdir(jp)
    # Allow the unpacked directory to either be insider another directory (as produced by
    # the buildbots) or directly inside the mapped directory (as produced by the BB script)
    if length(jp_contents) == 1
        jp = joinpath(jp, first(jp_contents))
    end
    jp
end

function runner_sandboxed_julia(install::String, args=``; registries_dir=joinpath(first(DEPOT_PATH), "registries"),
                                install_dir="/opt/julia",
                                stdin=stdin, stdout=stdout, stderr=stderr,
                                env::Dict{String,String}=Dict{String,String}(),
                                mounts::Dict{String,String}=Dict{String,String}(),
                                xvfb::Bool=true, cpus::Vector{Int}=Int[])
    julia_path = installed_julia_dir(install)
    rootfs = prepare_rootfs()
    read_only_maps = Dict(
        "/"                                 => rootfs.path,
        install_dir                         => julia_path,
        "/usr/local/share/julia/registries" => registries_dir,
    )

    artifacts_path = joinpath(storage_dir(), "artifacts")
    mkpath(artifacts_path)
    read_write_maps = merge(mounts, Dict(
        joinpath(rootfs.home, ".julia/artifacts")   => artifacts_path
    ))

    env = merge(env, Dict(
        # PkgEval detection
        "CI" => "true",
        "PKGEVAL" => "true",
        "JULIA_PKGEVAL" => "true",

        # use the provided registry
        # NOTE: putting a registry in a non-primary depot entry makes Pkg use it as-is,
        #       without needingb to set Pkg.UPDATED_REGISTRY_THIS_SESSION.
        "JULIA_DEPOT_PATH" => "::/usr/local/share/julia",

        # some essential env vars (since we don't run from a shell)
        "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
        "HOME" => rootfs.home,
    ))
    if haskey(ENV, "TERM")
        env["TERM"] = ENV["TERM"]
    end

    if xvfb
        lock(xvfb_lock) do
            if xvfb_proc[] === nothing || !process_running(xvfb_proc[])
                proc = Base.run(`Xvfb :1 -screen 0 1024x768x16`; wait=false)
                sleep(1)
                process_running(proc) || error("Could not start Xvfb")

                xvfb_proc[] === nothing && atexit() do
                    kill(xvfb_proc[])
                    wait(xvfb_proc[])
                end
                xvfb_proc[] = proc
            end
        end

        env["DISPLAY"] = ":1"
        read_write_maps["/tmp/.X11-unix"] = "/tmp/.X11-unix"
    end

    cmd = `$install_dir/bin/julia`

    # restrict resource usage
    if !isempty(cpus)
        cmd = `/usr/bin/taskset --cpu-list $(join(cpus, ',')) $cmd`
        env["JULIA_CPU_THREADS"] = string(length(cpus)) # JuliaLang/julia#35787
    end

    # NOTE: we use persist=true so that modifications to the rootfs are backed by
    #       actual storage on the host, and not just the (1G hard-coded) tmpfs,
    #       because some packages like to generate a lot of data during testing.

    config = SandboxConfig(read_only_maps, read_write_maps, env;
                           rootfs.uid, rootfs.gid, pwd=rootfs.home, persist=true,
                           stdin, stdout, stderr, verbose=isdebug(:sandbox))

    return config, `$cmd $args`
end

end # module
