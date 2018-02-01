using DataStreams
"""
Implement the `Data.Source` interface in the `DataStreams.jl` package.

"""
mutable struct Source{I} <: Data.Source
    schema::Data.Schema
    options::Options
    io::I
    fullpath::String
    datapos::Int # the position in the IOBuffer where the rows of data begins
    currentline::Vector{String}
end

function Base.show(io::IO, f::Source)
    println(io, "FWF.Source: ", f.fullpath)
    println(io, "Currentline   : ")
    show(io, f.currentline)
    println(io)
    show(io, f.options)
    show(io, f.schema)
end

# countlines only counts newlines not number of lines in the file.
# Quick fix to ensure last lines of data are counted.
# A line is anything except \n in the previous position
function fixed_countlines(io::IO) 
    b=[UInt8(0)]::Vector{UInt8}
    l = countlines(io)
    readbytes!(skip(io, -1), b, 1)
    (b[1] == UInt8('\n')) ? l : l+1
end

# Negative values will break these functions

function row_calc(io::IO, rows::Int, skip::Int, header::Bool)
    return row_calc(io, rows, skip) - (header?1:0)
end

function row_calc(io::IO, rows::Int, skip::Int, header::T) where {T}
    return row_calc(io, rows, skip)
end

function row_calc(io::IO, rows::Int, skip::Int)
    # rows to process, subtract skip and header if they exist
    lines = fixed_countlines(io)
    rows = rows <= 0 ?  lines : ( (lines < rows) ? (lines) : (rows))
    return skip > 1 ? rows - skip : rows
end


function calculate_ranges(columnwidths::Union{Vector{UnitRange{Int}}, Vector{Int}})
    rangewidths = Vector{UnitRange{Int}}(length(columnwidths))
    if isa(columnwidths, Vector{Int})
        l = 0
        for i in eachindex(columnwidths)
            columnwidths[i] < 1 && (throw(ArgumentError("A column width less than 1")))
            rangewidths[i] = l+1:l+columnwidths[i]
            l=last(rangewidths[i])
        end
    else
        #Validate we have an unbroken range wile copying
        first(first(columnwidths)) <= 0 && (throw(ArgumentError("Columns must start > 0")))
        for i in 1:length(columnwidths)
            rangewidths[i] = columnwidths[i]
            i==1 && (continue)
            (last(columnwidths[i-1])+1 != first(columnwidths[i])) && (throw(ArgumentError("Non-Continuous ranges "*string(columnwidths[i-1])*","*string(columnwidths[i])))) 
        end
    end
    return rangewidths
end

# Create a source data strcuture.  To do this we need to do the following
# * Ensure file exists and open for reading
# * Determine column names
# * Determine column types
# * Determine number of rows we will read
# * Convert missings to a dictionary, if applicable
# * Convert date formats to a dictionary, if applicable

function Source(
    fullpath::Union{AbstractString, IO},
    columnwidths::Union{Vector{UnitRange{Int}}, Vector{Int}}
    ;
    missingcheck::Bool=true,
    trimstrings::Bool=true,
    skiponerror::Bool=true,
    use_mmap::Bool=true,
    skip::Int=0,
    rows::Int=0,
    types::Vector=Vector(),
    header::Union{Bool, Vector{String}}=Vector{String}(),
    missings::Vector{String}=Vector{String}()
    )
    # Appemtping to re-create all objects here to minimize outside tampering
    datedict = Dict{Int, DateFormat}()
    typelist = Vector{DataType}()
    headerlist = Vector{String}()
    missingdict = Dict{String, Missing}()
    rangewidths = Vector{UnitRange{Int}}()

    isa(fullpath, AbstractString) && (isfile(fullpath) || throw(ArgumentError("\"$fullpath\" is not a valid file")))
    
    # open the file and prepare for procesing
    if isa(fullpath, IOBuffer)
        source = fullpath
        fs = nb_available(fullpath)
        fullpath = "<IOBuffer>"
    elseif isa(fullpath, IO)
        source = IOBuffer(Base.read(fullpath))
        fs = nb_available(source)
        fullpath = isdefined(fullpath, :name) ? fullpath.name : "__IO__"
    else
        source = open(fullpath, "r") do f
            IOBuffer(use_mmap ? Mmap.mmap(f) : Base.read(f))
        end
        fs = filesize(fullpath)
    end

    # Starting position
    startpos = position(source)
    # rows to process, subtract skip and header if they exist
    rows = row_calc(source, rows,skip, header)
    rows < 0 && (throw(ArgumentError("More skips than rows available")))
    # Go back to start
    seek(source, startpos)

    # Don't think this is necessary, but just in case utf sneaks in...BOM character detection
    if fs > 0 && Base.peek(source) == 0xef
         read(source, UInt8)
         read(source, UInt8) == 0xbb || seek(source, startpos)
         read(source, UInt8) == 0xbf || seek(source, startpos)
    end

    # Number of columns = # of widths
    isempty(columnwidths) && throw(ArgumentError("No column widths provided"))
    columns = length(columnwidths)

    rangewidths = calculate_ranges(columnwidths)
    rowlength = last(last(rangewidths))

    # reposition iobuffer
    tmp = skip
    while (!eof(source)) && (tmp > 1)
        readline(source)  
        tmp =- 1     
    end
    datapos = position(source)

    # Figure out headers
    if isa(header, Bool) && header
        # first row is heders
        FWF.readsplitline!(headerlist, source, rangewidths, true)
        datapos = position(source)
        for i in eachindex(headerlist)
            length(headerlist[i]) < 1 && (headerlist[i] = "Column$i")
        end
    elseif (isa(header, Bool) && !header) || isempty(header)
        # number columns
        headerlist = ["Column$i" for i = 1:columns]
    elseif !isempty(header)
        length(header) != columns && (throw(ArgumentError("Header count doesn't match column count"))) 
        headerlist = copy(header)
    else
        throw(ArgumentError("Can not determine headers")) 
    end
    
    # Type is set to String if types are not passed in
    # Otherwise iterate through copying types & creating date dictionary
    if isempty(types)
        typelist = [String for i = 1:columns]
    else
        length(types) != columns && throw(ArgumentError("Wrong number of types: "*string(length(types))))
        typelist = Vector{DataType}(columns)
        for i in 1:length(types)
            if (isa(types[i], DateFormat))
                typelist[i] = Date
                datedict[i] = types[i]
            elseif (isa(types[i], DataType))
                !(types[i] in (Int, Float64, String)) && (throw(ArgumentError("Invalid Type: "*string(types[i]))))
                typelist[i] = types[i]
            else
               throw(ArgumentError("Found type that is not a DateFormat or DataType")) 
            end
        end
    end

    # Convert missings to dictionary for faster lookup later.
    if !isempty(missings) 
        for entry in missings
            missingdict[entry] = missing
        end
    end

    sch = Data.Schema(typelist, headerlist, ifelse(rows < 0, missing, rows))
    opt = Options(missingcheck=missingcheck, trimstrings=trimstrings, 
                    skiponerror=skiponerror, skip=skip, missingvals=missingdict, 
                    dateformats = datedict,
                    columnrange=rangewidths)
    return Source(sch, opt, source, string(fullpath), datapos, Vector{String}())
end

# needed? construct a new Source from a Sink
#Source(s::CSV.Sink) = CSV.Source(fullpath=s.fullpath, options=s.options)
Data.reset!(s::FWF.Source) = (seek(s.io, s.datapos); return nothing)
Data.schema(source::FWF.Source) = source.schema
Data.accesspattern(::Type{<:FWF.Source}) = Data.Sequential
@inline Data.isdone(io::FWF.Source, row, col, rows, cols) = eof(io.io) || (!ismissing(rows) && row > rows)
@inline Data.isdone(io::Source, row, col) = Data.isdone(io, row, col, size(io.schema)...)
Data.streamtype(::Type{<:FWF.Source}, ::Type{Data.Column}) = true
#@inline Data.streamfrom(source::FWF.Source, ::Type{Data.Field}, ::Type{T}, row, col::Int) where {T} = FWF.parsefield(source.io, T, source.options, row, col)
Data.streamfrom(source::FWF.Source, ::Type{Data.Column}, ::Type{T}, col::Int) where {T} = FWF.parsefield(source, T, col)
Data.reference(source::FWF.Source) = source.io.data
