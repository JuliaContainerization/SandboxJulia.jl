using Test, SandboxJulia

script = """
       using Pkg;
       Pkg.add("Example")
       using Example
       """

run_sandboxed_julia(`-e $script`; privileged=true)
