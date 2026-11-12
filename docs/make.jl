using Documenter
using ClusterScripts

makedocs(
    sitename="ClusterScripts",
    format=Documenter.HTML(
        prettyurls=get(ENV, "CI", nothing) == "true"
    ),
    modules=[ClusterScripts],
    pages=[
        "Home" => "index.md",
        "Results database" => "database.md",
        "API" => "API.md"
    ]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo = "https://github.com/NQCD/ClusterScripts.jl.git"
)
