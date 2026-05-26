"""Support for the ILP data ingestion protocol in QuestDB"""
module QuestILP

using Dates: Date, Dates, DateTime
using HTTP: HTTP
using Logging

export ILPColumn, ILPMessage, ILPSymbol, ILPTable, ILPTimestamp, ILPValue
export ilpingest

"""converts `v` to microseconds since the unix epoch"""
toepochmicros(v::DateTime)::Int64 = round(Int64, Dates.datetime2unix(v) * 1e6)
toepochmicros(v::Date)::Int64 = toepochmicros(DateTime(v))
fromepochmicros(μs::Int64)::DateTime = Dates.unix2datetime(μs / 1e6)

"""converts `v` to nanoseconds since the unix epoch"""
toepochnanos(v::DateTime)::Int64 = round(Int64, Dates.datetime2unix(v) * 1e9)
toepochnanos(v::Date)::Int64 = toepochnanos(DateTime(v))
fromepochnanos(ns::Int64)::DateTime = Dates.unix2datetime(ns / 1e9)

"""
    ilp_tablename(s)

Converts `s` into a valid ILP table name if possible. Raises `ArgumentError` if
no conversion is possible.

See [Name restrictions](https://questdb.com/docs/ingestion/ilp/advanced-settings/#name-restrictions)
"""
function ilp_tablename(s::AbstractString)
    for c in s
        if !isprint(c) || c in
           ('\n', '\r', '?', ',', '”', '"', '\\', '/', ':', ')', '(', '+', '*', '%', '~')
            throw(ArgumentError("table name $s is invalid due to character $c"))
        end
    end
    if s[begin] == '.'
        throw(ArgumentError("table name $s is invalid due to leading '.'"))
    end
    if s[end] == '.'
        throw(ArgumentError("table name $s is invalid due to trailing '.'"))
    end
    return replace(s, ' ' => "\\ ")
end

"""
    ILPTable(name)

Wraps `name` as an ILP table name.

See [Name restrictions](https://questdb.com/docs/ingestion/ilp/advanced-settings/#name-restrictions)
"""
struct ILPTable
    name::String
    ilp_name::String
    function ILPTable(name::AbstractString)
        name = string(name)
        ilp_name = ilp_tablename(name)
        new(name, ilp_name)
    end
end

Base.print(io::IO, x::ILPTable) = print(io, x.ilp_name)

"""
    ilp_colname(s)

Converts `s` into a valid ILP column name (either symbolset or columnset).

See [name restrictions](https://questdb.com/docs/ingestion/ilp/advanced-settings/#name-restrictions)
"""
function ilp_colname(s::AbstractString)
    for c in s
        if !isprint(c) || c in (
            '\n',
            '\r',
            '?',
            '.',
            ',',
            '”',
            '"',
            '\\',
            '/',
            ':',
            ')',
            '(',
            '+',
            '-',
            '*',
            '%',
            '~',
        )
            # TODO: fix so \ is supported but \\ is not
            # TODO: fix so \ and * are supported but \* is not
            # TODO: fix so % is supported but %% is not
            throw(ArgumentError("table name $s is invalid due to character $c"))
        end
    end
    return replace(s, ' ' => "\\ ")
end

"""
    ILPColumn(name)

Wraps `name` as an ILP column name (either symbolset or columnset).

See [name restrictions](https://questdb.com/docs/ingestion/ilp/advanced-settings/#name-restrictions)
"""
struct ILPColumn
    name::String
    ilp_name::String
    function ILPColumn(name::AbstractString)
        name = string(name)
        ilp_name = ilp_colname(name)
        new(name, ilp_name)
    end
end

Base.print(io::IO, x::ILPColumn) = print(io, x.ilp_name)

"""
    ILPSymbol(value)

Wraps `value` as an ILP symbolset value.

Note that high-cardinality types are not good candidates for symbols. As a
precaution, the `ILPSymbol` constructor does not permit floats or decimals.

See [symbolset values](https://questdb.com/docs/ingestion/ilp/advanced-settings/#symbolset-values)
"""
struct ILPSymbol{T<:Union{Integer,AbstractString}}
    value::T
end

Base.print(io::IO, x::ILPSymbol{T}) where {T<:Integer} = print(io, x.value, 'i')
function Base.print(io::IO, x::ILPSymbol{T}) where {T<:Unsigned}
    print(io, "0x", string(x.value, base=16), 'i')
end
Base.print(io::IO, x::ILPSymbol{Bool}) = print(io, x.value ? 't' : 'f')
function Base.print(io::IO, x::ILPSymbol{T}) where {T<:AbstractString}
    replace(
        io,
        x.value,
        ' ' => "\\ ",
        '=' => "\\=",
        ',' => "\\,",
        '\n' => "\\\n",
        '\r' => "\\\r",
        '\\' => "\\\\",
    )
end

"""
    ILPValue(value)

Wraps `value` as an ILP columnset value.

See [columset value types](https://questdb.com/docs/ingestion/ilp/columnset-types/)
"""
struct ILPValue{T<:Union{Integer,AbstractFloat,AbstractString,Date,DateTime}}
    value::T
end

Base.print(io::IO, x::ILPValue{T}) where {T<:Integer} = print(io, x.value, 'i')
function Base.print(io::IO, x::ILPValue{T}) where {T<:Unsigned}
    print(io, "0x", string(x.value, base=16), 'i')
end
Base.print(io::IO, x::ILPValue{T}) where {T<:AbstractFloat} = print(io, x.value)  # TODO: consider performance of `Printf.@printf(buf, "%.6f", x.value)` (or similar)
# See QuestILPDecimals.jl for decimal support
Base.print(io::IO, x::ILPValue{Bool}) = print(io, x.value ? 't' : 'f')
function Base.print(io::IO, x::ILPValue{T}) where {T<:AbstractString}
    write(io, '"')
    replace(io, x.value, '"' => "\\\"", '\n' => "\\\n", '\r' => "\\\r", '\\' => "\\\\")
    write(io, '"')
end
function Base.print(io::IO, x::ILPValue{T}) where {T<:Union{Date,DateTime}}
    print(io, toepochmicros(x.value), 't')
end

"""
    ILPTimestamp(value)

Wraps `value` as an ILP designated timestamp.

See [Designated timestamp](https://questdb.com/docs/ingestion/ilp/advanced-settings/#designated-timestamp).
"""
struct ILPTimestamp{T<:Union{Date,DateTime}}
    value::T
end

Base.print(io::IO, x::ILPTimestamp) = print(io, toepochnanos(x.value))

"""
    ILPMessage(table, symbolset, columnset, timestamp)

Wraps arguments as an ILPMessage.

See [ILP message syntax](https://questdb.com/docs/ingestion/ilp/advanced-settings/#syntax)
"""
struct ILPMessage
    table::ILPTable
    symbolset::Vector{Pair{ILPColumn,ILPSymbol}}
    columnset::Vector{Pair{ILPColumn,ILPValue}}
    timestamp::ILPTimestamp
end

"""
    ILPMessage(elements...)

Infers each of `elements` by type to create an `ILPMessage`
"""
function ILPMessage(elements...)
    # declare variables
    local table::ILPTable
    symbolset = Pair{ILPColumn,ILPSymbol}[]
    columnset = Pair{ILPColumn,ILPValue}[]
    local timestamp::ILPTimestamp

    # sort elements
    for e in elements
        if e isa ILPTable
            table = e
        elseif e isa Pair{<:ILPColumn,<:ILPSymbol}
            push!(symbolset, e)
        elseif e isa Pair{<:ILPColumn,<:ILPValue}
            push!(columnset, e)
        elseif e isa ILPTimestamp
            timestamp = e
        else
            throw(ArgumentError("unexpected message element $e (type: $(typeof(e)))"))
        end
    end

    # build message
    return ILPMessage(table, symbolset, columnset, timestamp)
end

function Base.print(io::IO, x::ILPMessage)
    print(io, x.table)
    for p in x.symbolset
        print(io, ',', p.first, '=', p.second)
    end
    if length(x.columnset) > 0
        print(io, ' ')
        for (i, p) in enumerate(x.columnset)
            if i > 1
                print(io, ',')
            end
            print(io, p.first, '=', p.second)
        end
    end
    print(io, ' ', x.timestamp, '\n')
end

"""
    ilpingest(messages::Channel{ILPMessage}; <keyword arguments>)

Sends `messages` to a QuestDB instance via ILP over HTTP

# Arguments
- `host::AbstractString`: the hostname for the HTTP endpoint
- `port::Integer`: the port for the HTTP endpoint
- `max_bytes::Integer`: the maximum number of bytes to write in a single batch (default: 50M)
- `max_rows::Integer`: the maximum number of rows (records) in a single batch (default: 75K)
- `max_seconds::Number`: the maximum number of seconds to wait before sending a batch (default: 30)

A batch will be sent when the first limit (bytes, rows, or seconds) is reached.
"""
function ilpingest(
    messages::Channel{ILPMessage};
    host::AbstractString="localhost",
    port::Integer=9000,
    max_bytes::Integer=50_000_000,
    max_rows::Integer=75_000,
    max_seconds::Number=30.0,
)
    @debug "starting ilpingest..."

    # configure endpoint
    url = "http://$host:$port/write"
    headers = ["Content-Type" => "text/plain; charset=utf-8"]

    # create a new buffer to hold up to `max_bytes`
    buf = IOBuffer(; sizehint=max_bytes)

    last_send = time()
    num_rows = 0
    for msg in messages
        print(buf, msg)
        num_rows += 1
        elapsed = time() - last_send
        if position(buf) >= max_bytes || num_rows >= max_rows || elapsed >= max_seconds
            @debug "Sending a buffer of $(position(buf)) bytes to $url"
            @debug "Preparing `buf` for reading"
            seekstart(buf)
            @debug "Sending `buf` to the /write endpoint"
            _ = HTTP.post(url, headers, buf; status_exception=true)
            @debug "Response obtained; resetting buffer for reuse"
            seekstart(buf)
            truncate(buf, 0)
            num_rows = 0
            last_send = time()
        end
    end

    # handle final batch
    if position(buf) > 0
        @debug "Sending final buffer of $(position(buf)) bytes to $url"
        @debug "Preparing `buf` for reading"
        seekstart(buf)
        @debug "Sending `buf` to the /write endpoint"
        _ = HTTP.post(url, headers, buf; status_exception=true)
        @debug "Final response obtained"
    end

    @debug "ilpingest done"
end

end # module QuestILP
