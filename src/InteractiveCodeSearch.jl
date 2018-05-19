module InteractiveCodeSearch
export @search, @searchmethods

using Base: find_source_file

@static if VERSION < v"0.7-"
    const Nothing = Void
    const findall = find
    const _ismatch = ismatch
    const _readandwrite = readandwrite
    const _fetch = wait
    allnames(x) = names(x, true)
    macro info(x)
        :(info($(esc(x))))
    end
else
    using InteractiveUtils: edit
    const _fetch = fetch
    allnames(x) = names(x, all=true)
    _ismatch(r, s) = occursin(r, s)
    function _readandwrite(cmds)
        processes = open(cmds, "r+")
        return (processes.out, processes.in, processes)
    end
end

mutable struct SearchConfig  # CONFIG
    open
    interactive_matcher
    auto_open
end

is_identifier(s) = _ismatch(r"^@?[a-z_]+$"i, string(s))

is_locatables(::Any) = false
is_locatables(::Base.Callable) = true

function list_locatables(m::Module)
    locs = []
    for s in allnames(m)
        if is_identifier(s)
            x = try
                getfield(m, s)
            catch err
                err isa UndefVarError && continue
                rethrow()
            end
            if is_locatables(x)
                push!(locs, x)
            end
        end
    end
    return locs
end

module_methods(m::Module) :: Vector{Method} =
    vcat(collect.(methods.(list_locatables(m)))...)


struct _Dummy end

function uninteresting_locs()
    locs = []
    for m in methods(_Dummy)
        path = string(m.file)
        if path != @__FILE__
            push!(locs, (path, m.line))
        end
    end
    return locs
end


function read_stdout(cmd, input)
    stdout, stdin, process = _readandwrite(cmd)
    reader = @async read(stdout)
    write(stdin, input)
    close(stdin)
    return _fetch(reader)
end

function parse_loc(line)
    rest, lineno = rsplit(line, ":", limit=2)
    _, path = rsplit(rest, " at ", limit=2)
    return String(path), parse(Int, lineno)
end

run_matcher(input) = String(read_stdout(CONFIG.interactive_matcher, input))

function choose_method(methods)
    if CONFIG.auto_open && length(methods) == 1
        m = first(methods)
        loc = (string(m.file), m.line)
        if loc in uninteresting_locs()
            path, lineno = loc
            @info "Not opening uninteresting location: $path:$lineno"
            return
        end
        return loc
    end
    out = run_matcher(join(map(string, methods), "\n"))
    if isempty(out)
        return
    end
    return parse_loc(out)
end

function run_open(path, lineno)
    @info "Opening $path:$lineno"
    CONFIG.open(find_source_file(path), lineno)
end

maybe_open(::Nothing) = nothing
maybe_open(x::Tuple{String, Integer}) = run_open(x...)

search_methods(methods) = maybe_open(choose_method(methods))


code_search(f, t) = search_methods(methods(f, t))
code_search(f::Base.Callable) = search_methods(methods(f))
code_search(m::Module) = search_methods(module_methods(m))

function code_search(::T) where T
    warn("Cannot search for given value of type $T; searching for its type instead...")
    code_search(T)
end

const CONFIG = SearchConfig(
    edit,                       # open
    `peco`,                     # interactive_matcher
    true,                       # auto_open
)

isline(::Any) = false
isline(ex::Expr) = ex.head == :line
try
    @eval isline(::LineNumberNode) = true
catch err
    err isa UndefVarError || rethrow()
end

single_macrocall(::Any) = nothing
function single_macrocall(x::Expr)
    if x.head == :macrocall && all(isline.(x.args[2:end]))
        return x.args[1]
    elseif x.head == :block
        statements = findall(a -> !isline(a), x.args)
        if length(statements) == 1
            return single_macrocall(x.args[statements[1]])
        end
    end
    return nothing
end

explicitly_typed(::Any) = nothing
function explicitly_typed(ex::Expr)
    if ex.head == :call &&
            all(x isa Expr && x.head == :(::) for x in ex.args[2:end])
        return ex.args[1], [x.args[end] for x in ex.args[2:end]]
    end
    return nothing
end

"""
    @search x

List file locations at which `x` are defined in an interactive matcher
and then open the chosen location in the editor.

See also `?InteractiveCodeSearch`
"""
macro search(x)
    if x isa Symbol || x isa Expr && x.head == :.
        :(code_search($(esc(x))))
    else
        macrocall = single_macrocall(x)
        if macrocall !== nothing
            return :(code_search($(esc(macrocall))))
        end

        func_type = explicitly_typed(x)
        if func_type !== nothing
            f, ts = func_type
            return :(code_search($(esc(f)), tuple($(esc.(ts)...))))
        end

        Base.gen_call_with_extracted_types(code_search, x)
    end
end

code_search_methods(T) = search_methods(methodswith(T))

"""
    @searchmethods x
    @searchmethods ::X

Interactively search through `methodswith(typeof(x))` or
`methodswith(X)`.
"""
macro searchmethods(x)
    if x isa Expr && x.head == :(::)
        if length(x.args) > 1
            @info "Ignoring: $(x.args[1:end-1]...) in $x"
        end
        :(code_search_methods($(esc(x.args[end]))))
    else
        :(code_search_methods(typeof($(esc(x)))))
    end
end

end # module
