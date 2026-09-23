#=
Self-describing value codec for the results database.

Every value is either stored as a *scalar* (a native SQLite INTEGER/REAL/TEXT/NULL plus a
`vtype` tag recording the exact Julia type), or as an *array*: a small JSON structure header
plus one concatenated byte buffer holding the raw (column-major, little-endian) payload of all
leaves. The header is a tree of nodes, each tagged with `"t"`:

- `dense`:       isbits array (`eltype` from `DENSE_ELTYPES`) with `shape`, `offset`, `nbytes`.
- `categorical`: `Array{Symbol}`/`Array{String}` stored as `levels` plus a `codes` dense child.
- `stacked`:     Vector of equal-shape dense arrays stored as one `(inner_shape..., n)` buffer.
- `list`:        Vector with one child node per element (ragged / heterogeneous vectors).
- `tuple`, `namedtuple`, `arraypartition`, `dict`: containers with child nodes.
- `scalar`, `nothing`, `missing`: scalar leaves inside containers (value inline as a string).
- `serialized`:  last-resort `Serialization` stdlib blob (Julia-version dependent).

Offsets are relative to the *uncompressed* buffer. The root node additionally carries `"v"`,
the codec version.
=#

const CODEC_VERSION = 1

"Minimum payload size in bytes before compression is attempted."
const COMPRESSION_THRESHOLD = 128

const DENSE_ELTYPES = Dict{String,DataType}(
    string(T) => T for T in (
        Float16, Float32, Float64,
        Int8, Int16, Int32, Int64,
        UInt8, UInt16, UInt32, UInt64,
        Bool, ComplexF32, ComplexF64,
    )
)
const DenseEltype = Union{values(DENSE_ELTYPES)...}

"Scalar types stored natively in SQLite columns (and inline in `scalar` header nodes)."
const ScalarType = Union{Bool,Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32,UInt64,
    Float16,Float32,Float64,String,Symbol,Char,Nothing,Missing}

"""
    EncodedValue

Result of [`encode_value`](@ref). For `kind == :scalar`, `value` holds the SQLite-bindable value
and `vtype` the Julia type name. For `kind == :array`, `header`, `codec`, `raw_nbytes` and `data`
describe the blob. For `kind == :repr` (parameters only), `value` holds `repr(x)`.
"""
struct EncodedValue
    kind::Symbol
    vtype::String
    value::Any
    header::String
    codec::String
    raw_nbytes::Int
    data::Vector{UInt8}
end

struct UnencodableError <: Exception
    type::Type
end
Base.showerror(io::IO, e::UnencodableError) =
    print(io, "Values of type $(e.type) can only be stored with the `serialized` fallback.")

mutable struct EncodeContext
    buffer::IOBuffer
    allow_serialized::Bool
end

# ----------------------------------------------------------------------------------------------
# Scalars
# ----------------------------------------------------------------------------------------------

scalar_sql_value(x::Union{Bool,Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32}) = Int64(x)
scalar_sql_value(x::UInt64) = reinterpret(Int64, x)
scalar_sql_value(x::Union{Float16,Float32,Float64}) = Float64(x)
scalar_sql_value(x::Union{String,Symbol,Char}) = string(x)
scalar_sql_value(::Union{Nothing,Missing}) = missing

"""
    decode_scalar(vtype::AbstractString, value)

Convert a value read from a SQLite column back to the Julia type named by `vtype`.
Floats stored as NaN are returned by SQLite as NULL and are restored as `NaN`.
"""
function decode_scalar(vtype::AbstractString, value)
    vtype == "Nothing" && return nothing
    vtype == "Missing" && return missing
    vtype == "String" && return String(value)
    vtype == "Symbol" && return Symbol(value)
    vtype == "Char" && return only(value)
    T = DENSE_ELTYPES[vtype]
    if T <: AbstractFloat
        return ismissing(value) ? T(NaN) : T(value)
    elseif T === UInt64
        return reinterpret(UInt64, Int64(value))
    else
        return T(value)
    end
end

# Inline (JSON string) form used for scalars nested inside containers.
scalar_node(x::ScalarType) = (t = "scalar", vtype = string(typeof(x)), v = string(x))
scalar_node(::Nothing) = (t = "nothing",)
scalar_node(::Missing) = (t = "missing",)

function parse_inline_scalar(vtype::AbstractString, v::AbstractString)
    vtype == "String" && return String(v)
    vtype == "Symbol" && return Symbol(v)
    vtype == "Char" && return only(v)
    T = DENSE_ELTYPES[vtype]
    return T === Bool ? v == "true" : parse(T, v)
end

# ----------------------------------------------------------------------------------------------
# Encoding: `encode_node(x, ctx)` writes any payload to `ctx.buffer` and returns a header node.
# Add methods for new types; pair them with a `decode_node(::Val{:tag}, node, buffer)` method.
# ----------------------------------------------------------------------------------------------

function write_leaf!(ctx::EncodeContext, x::Array{T}) where {T<:DenseEltype}
    offset = position(ctx.buffer)
    nbytes = write(ctx.buffer, x)
    return offset, nbytes
end

function dense_node(ctx::EncodeContext, x::AbstractArray{T}; as = nothing) where {T<:DenseEltype}
    offset, nbytes = write_leaf!(ctx, x isa Array ? x : collect(x))
    node = (t = "dense", eltype = string(T), shape = Int[size(x)...], offset = offset, nbytes = nbytes)
    return isnothing(as) ? node : merge(node, (as = as,))
end

encode_node(x::ScalarType, ctx::EncodeContext) = scalar_node(x)

# Complex scalars become 0-d dense leaves.
encode_node(x::Union{ComplexF32,ComplexF64}, ctx::EncodeContext) = merge(dense_node(ctx, fill(x)), (scalar = true,))

encode_node(x::AbstractArray{<:DenseEltype}, ctx::EncodeContext) = dense_node(ctx, x)
encode_node(x::AbstractVector{<:DenseEltype}, ctx::EncodeContext) = dense_node(ctx, x)

encode_node(x::AbstractVector{T}, ctx::EncodeContext) where {T<:Union{Symbol,String}} = categorical_node(ctx, x)
encode_node(x::AbstractArray{T}, ctx::EncodeContext) where {T<:Union{Symbol,String}} = categorical_node(ctx, x)

function categorical_node(ctx::EncodeContext, x::AbstractArray{T}) where {T<:Union{Symbol,String}}
    levels = T[]
    lookup = Dict{T,Int}()
    codes = Vector{Int}(undef, length(x))
    for (i, v) in enumerate(x)
        codes[i] = get!(lookup, v) do
            push!(levels, v)
            length(levels)
        end
    end
    CodeT = length(levels) <= typemax(UInt8) ? UInt8 :
            length(levels) <= typemax(UInt16) ? UInt16 : UInt32
    return (
        t = "categorical",
        eltype = string(T),
        levels = string.(levels),
        codes = dense_node(ctx, reshape(convert(Vector{CodeT}, codes), size(x))),
    )
end

# Generic vectors: pick the most compact representation that reproduces the vector exactly.
function encode_node(x::AbstractVector, ctx::EncodeContext)
    E = eltype(x)
    if !isempty(x)
        # Homogeneous isbits elements in an abstractly-typed vector (e.g. `Vector{Any}` of Ints).
        S = typeof(first(x))
        if S <: DenseEltype && all(v -> typeof(v) === S, x)
            return dense_node(ctx, convert(Vector{S}, x); as = string(E))
        end
        # Equal-shape dense arrays (e.g. trajectory frames) share one contiguous buffer.
        if S <: Array && eltype(S) <: DenseEltype
            shape = size(first(x))
            if all(v -> typeof(v) === S && size(v) == shape, x)
                offset = position(ctx.buffer)
                nbytes = sum(v -> write(ctx.buffer, v), x)
                return (
                    t = "stacked", eltype = string(eltype(S)), inner_shape = Int[shape...],
                    n = length(x), vector_eltype = string(E), offset = offset, nbytes = nbytes,
                )
            end
        end
    end
    return (t = "list", vector_eltype = string(E), items = Any[encode_node(v, ctx) for v in x])
end

encode_node(x::Tuple, ctx::EncodeContext) = (t = "tuple", items = Any[encode_node(v, ctx) for v in x])

encode_node(x::NamedTuple, ctx::EncodeContext) = (
    t = "namedtuple",
    names = collect(string.(keys(x))),
    items = Any[encode_node(v, ctx) for v in values(x)],
)

encode_node(x::RecursiveArrayTools.ArrayPartition, ctx::EncodeContext) =
    (t = "arraypartition", items = Any[encode_node(v, ctx) for v in x.x])

function encode_node(x::Dict, ctx::EncodeContext)
    ks = collect(keys(x))
    return (
        t = "dict",
        keytype = string(keytype(x)),
        valtype = string(valtype(x)),
        keys = encode_node(ks, ctx),
        values = encode_node([x[k] for k in ks], ctx),
    )
end

function encode_node(x, ctx::EncodeContext)
    ctx.allow_serialized || throw(UnencodableError(typeof(x)))
    @warn "No codec for values of type $(typeof(x)); falling back to the Serialization stdlib. " *
          "These values can only be read back with a compatible Julia version and with the " *
          "defining packages loaded." maxlog = 1
    offset = position(ctx.buffer)
    Serialization.serialize(ctx.buffer, x)
    return (t = "serialized", jl_type = string(typeof(x)), offset = offset,
        nbytes = position(ctx.buffer) - offset)
end

# ----------------------------------------------------------------------------------------------
# Top-level encode
# ----------------------------------------------------------------------------------------------

compression_level(compress::Bool) = compress ? 3 : 0
compression_level(level::Integer) = Int(level)

function compress_payload(raw::Vector{UInt8}, level::Int)
    if level > 0 && length(raw) >= COMPRESSION_THRESHOLD
        compressed = transcode(ZstdCompressor(; level = level), raw)
        length(compressed) < length(raw) && return "zstd", compressed
    end
    return "none", raw
end

"""
    encode_value(x; compress=true, allow_serialized=true)::EncodedValue

Encode a Julia value for storage in the results database. Scalars (numbers, strings, symbols,
`nothing`) are stored natively; everything else becomes a JSON structure header plus a raw
byte payload, zstd-compressed if `compress` is `true` (level 3) or an integer level.

With `allow_serialized=false`, values without a dedicated codec throw an `UnencodableError`
instead of falling back to `Serialization`.
"""
function encode_value(x; compress = true, allow_serialized = true)
    if x isa ScalarType
        return EncodedValue(:scalar, string(typeof(x)), scalar_sql_value(x), "", "", 0, UInt8[])
    end
    ctx = EncodeContext(IOBuffer(), allow_serialized)
    node = merge((v = CODEC_VERSION,), encode_node(x, ctx))
    raw = take!(ctx.buffer)
    codec, data = compress_payload(raw, compression_level(compress))
    return EncodedValue(:array, "", missing, JSON.json(node), codec, length(raw), data)
end

"""
    encode_parameter(x; compress=true)::EncodedValue

Like [`encode_value`](@ref), but values without a dedicated codec (e.g. `Unitful.Quantity`,
NQCDynamics output types) are stored as their `repr` string (`kind == :repr`).
"""
function encode_parameter(x; compress = true)
    try
        return encode_value(x; compress = compress, allow_serialized = false)
    catch e
        e isa UnencodableError || rethrow()
        return EncodedValue(:repr, string(typeof(x)), repr(x), "", "", 0, UInt8[])
    end
end

# ----------------------------------------------------------------------------------------------
# Decoding
# ----------------------------------------------------------------------------------------------

const TYPE_CACHE = Dict{String,Any}()
const TYPE_CACHE_LOCK = ReentrantLock()

function lookup_type_symbol(s::Symbol)
    for m in (Core, Base, RecursiveArrayTools, @__MODULE__)
        isdefined(m, s) && return getfield(m, s)
    end
    for m in values(Base.loaded_modules)
        nameof(m) === s && return m
    end
    throw(ArgumentError("Unknown name $s"))
end

# Safe type-expression evaluator: only resolves names, module paths and type applications.
evaluate_type_expr(s::Symbol) = lookup_type_symbol(s)
evaluate_type_expr(x::Integer) = x
evaluate_type_expr(x::QuoteNode) = x.value
function evaluate_type_expr(ex::Expr)
    if ex.head === :curly
        return Core.apply_type(evaluate_type_expr(ex.args[1]), map(evaluate_type_expr, ex.args[2:end])...)
    elseif ex.head === :. && length(ex.args) == 2
        parent = evaluate_type_expr(ex.args[1])
        parent isa Module || throw(ArgumentError("Not a module: $parent"))
        return getfield(parent, evaluate_type_expr(ex.args[2]))
    elseif ex.head === :tuple
        return Tuple(map(evaluate_type_expr, ex.args))
    end
    throw(ArgumentError("Unsupported type expression $ex"))
end

"""
    resolve_type(name::AbstractString)

Resolve a type name recorded in a header (e.g. `"Union{Nothing, Float64}"`) without `eval`.
Returns `nothing` if the type cannot be resolved (e.g. its package is not loaded).
"""
function resolve_type(name::AbstractString)
    lock(TYPE_CACHE_LOCK) do
        get!(TYPE_CACHE, name) do
            try
                T = evaluate_type_expr(Meta.parse(name))
                T isa Type ? T : nothing
            catch
                nothing
            end
        end
    end
end

# Rebuild a vector with the recorded element type, falling back to the narrowest element type.
function typed_vector(items::AbstractVector, eltype_name)
    E = isnothing(eltype_name) ? nothing : resolve_type(eltype_name)
    if !isnothing(E)
        try
            return convert(Vector{E}, items)
        catch
        end
    end
    return isempty(items) ? Any[] : map(identity, items)
end

function read_dense(T::Type, shape::Tuple, offset::Int, nbytes::Int, buffer::Vector{UInt8})
    out = Array{T}(undef, shape)
    nbytes == sizeof(out) || error("Corrupt dense node: expected $(sizeof(out)) bytes, got $nbytes")
    offset + nbytes <= length(buffer) || error("Corrupt dense node: payload is truncated")
    GC.@preserve out buffer begin
        unsafe_copyto!(Ptr{UInt8}(pointer(out)), pointer(buffer, offset + 1), nbytes)
    end
    return out
end

read_dense(node, buffer::Vector{UInt8}) = read_dense(DENSE_ELTYPES[node["eltype"]],
    Tuple(Int.(node["shape"])), Int(node["offset"]), Int(node["nbytes"]), buffer)

decode_node(node, buffer::Vector{UInt8}) = decode_node(Val(Symbol(node["t"])), node, buffer)

function decode_node(::Val{:dense}, node, buffer)
    arr = read_dense(node, buffer)
    get(node, "scalar", false) && return arr[]
    if haskey(node, "as")
        E = resolve_type(node["as"])
        return isnothing(E) ? arr : convert(Array{E,ndims(arr)}, arr)
    end
    return arr
end

function decode_node(::Val{:categorical}, node, buffer)
    T = node["eltype"] == "Symbol" ? Symbol : String
    levels = T.(node["levels"])
    codes = read_dense(node["codes"], buffer)
    out = Array{T}(undef, size(codes))
    for i in eachindex(codes)
        out[i] = levels[codes[i]]
    end
    return out
end

function decode_node(::Val{:stacked}, node, buffer)
    T = DENSE_ELTYPES[node["eltype"]]
    inner_shape = Tuple(Int.(node["inner_shape"]))
    stride = prod(inner_shape; init = 1) * sizeof(T)
    offset = Int(node["offset"])
    items = [read_dense(T, inner_shape, offset + (i - 1) * stride, stride, buffer) for i in 1:Int(node["n"])]
    return typed_vector(items, get(node, "vector_eltype", nothing))
end

decode_node(::Val{:list}, node, buffer) =
    typed_vector(Any[decode_node(c, buffer) for c in node["items"]], get(node, "vector_eltype", nothing))

decode_node(::Val{:tuple}, node, buffer) = Tuple(decode_node(c, buffer) for c in node["items"])

decode_node(::Val{:namedtuple}, node, buffer) =
    NamedTuple{Tuple(Symbol.(node["names"]))}(Tuple(decode_node(c, buffer) for c in node["items"]))

decode_node(::Val{:arraypartition}, node, buffer) =
    RecursiveArrayTools.ArrayPartition((decode_node(c, buffer) for c in node["items"])...)

function decode_node(::Val{:dict}, node, buffer)
    ks = decode_node(node["keys"], buffer)
    vs = decode_node(node["values"], buffer)
    K = something(resolve_type(node["keytype"]), Any)
    V = something(resolve_type(node["valtype"]), Any)
    return Dict{K,V}(zip(ks, vs))
end

decode_node(::Val{:scalar}, node, buffer) = parse_inline_scalar(node["vtype"], node["v"])
decode_node(::Val{:nothing}, node, buffer) = nothing
decode_node(::Val{:missing}, node, buffer) = missing

function decode_node(::Val{:serialized}, node, buffer)
    offset = Int(node["offset"])
    return Serialization.deserialize(IOBuffer(view(buffer, offset+1:offset+Int(node["nbytes"]))))
end

function decompress_payload(codec::AbstractString, data::AbstractVector{UInt8})
    codec == "none" && return Vector{UInt8}(data)
    codec == "zstd" && return transcode(ZstdDecompressor, Vector{UInt8}(data))
    throw(ArgumentError("Unknown codec $codec"))
end

"""
    decode_value(header::AbstractString, codec::AbstractString, data)

Decode an array-kind value from its JSON structure header and (possibly compressed) payload.
"""
function decode_value(header::AbstractString, codec::AbstractString, data)
    node = JSON.parse(header)
    version = Int(get(node, "v", CODEC_VERSION))
    version <= CODEC_VERSION || error("Value was written with codec version $version, but this " *
                                      "version of ClusterScripts only supports up to $CODEC_VERSION.")
    return decode_node(node, decompress_payload(codec, ismissing(data) ? UInt8[] : data))
end

"Decode an [`EncodedValue`](@ref) directly (mainly for testing)."
function decode_value(e::EncodedValue)
    e.kind === :scalar && return decode_scalar(e.vtype, e.value)
    e.kind === :repr && return e.value
    return decode_value(e.header, e.codec, e.data)
end
