# Code Generator
# ==============

"""
Variable names used in generated code.

The following variable names may be used in the code.

- `p::Int`: current position of data
- `p_end::Int`: end position of data
- `p_eof::Int`: end position of file stream
- `ts::Int`: start position of token (tokenizer only)
- `te::Int`: end position of token (tokenizer only)
- `cs::Int`: current state
- `data::Any`: input data
- `mem::SizedMemory`: input data memory
- `byte::UInt8`: current data byte
"""
struct Variables
    p::Symbol
    p_end::Symbol
    p_eof::Symbol
    ts::Symbol
    te::Symbol
    cs::Symbol
    data::Symbol
    mem::Symbol
    byte::Symbol
end

struct CodeGenContext
    vars::Variables
    generator::Function
    checkbounds::Bool
    loopunroll::Int
    getbyte::Function
    clean::Bool
end

"""
    CodeGenContext(;
        vars=Variables(:p, :p_end, :p_eof, :ts, :te, :cs, :data, gensym(), gensym()),
        generator=:table,
        checkbounds=true,
        loopunroll=0,
        getbyte=Base.getindex,
        clean=false
    )

Create a code generation context.

Arguments
---------

- `vars`: variable names used in generated code
- `generator`: code generator (`:table`, `:inline` or `:goto`)
- `checkbounds`: flag of bounds check
- `loopunroll`: loop unroll factor (≥ 0)
- `getbyte`: function of byte access (i.e. `getbyte(data, p)`)
- `clean`: flag of code cleansing
"""
function CodeGenContext(;
        vars::Variables=Variables(:p, :p_end, :p_eof, :ts, :te, :cs, :data, gensym(), gensym()),
        generator::Symbol=:table,
        checkbounds::Bool=true,
        loopunroll::Integer=0,
        getbyte::Function=Base.getindex,
        clean::Bool=false)
    if loopunroll < 0
        throw(ArgumentError("loop unroll factor must be a non-negative integer"))
    elseif loopunroll > 0 && generator != :goto
        throw(ArgumentError("loop unrolling is not supported for $(generator)"))
    end
    # special conditions for simd generator
    if generator == :simd
        if loopunroll != 0
            throw(ArgumentError("SIMD generator does not support unrolling"))
        elseif getbyte != Base.getindex
            throw(ArgumentError("SIMD generator only support Base.getindex"))
        elseif checkbounds
            throw(ArgumentError("SIMD generator does not support boundscheck"))
        end
    end
    # check generator
    if generator == :table
        generator = generate_table_code
    elseif generator == :inline
        generator = generate_inline_code
    elseif generator == :goto
        generator = generate_goto_code
    elseif generator == :simd
        generator = generate_simd_code
    else
        throw(ArgumentError("invalid code generator: $(generator)"))
    end
    return CodeGenContext(vars, generator, checkbounds, loopunroll, getbyte, clean)
end

"""
    generate_init_code(context::CodeGenContext, machine::Machine)::Expr

Generate variable initialization code.
"""
function generate_init_code(ctx::CodeGenContext, machine::Machine)
    return quote
        $(ctx.vars.p)::Int = 1
        $(ctx.vars.p_end)::Int = 0
        $(ctx.vars.p_eof)::Int = -1
        $(ctx.vars.cs)::Int = $(machine.start_state)
    end
end

"""
    generate_exec_code(ctx::CodeGenContext, machine::Machine, actions=nothing)::Expr

Generate machine execution code with actions.
"""
function generate_exec_code(ctx::CodeGenContext, machine::Machine, actions=nothing)
    # make actions
    if actions === nothing
        actions = Dict{Symbol,Expr}(a => quote nothing end for a in action_names(machine))
    elseif actions == :debug
        actions = debug_actions(machine)
    elseif isa(actions, AbstractDict{Symbol,Expr})
        actions = Dict{Symbol,Expr}(collect(actions))
    else
        throw(ArgumentError("invalid actions argument"))
    end
    # generate code
    code = ctx.generator(ctx, machine, actions)
    if ctx.clean
        code = cleanup(code)
    end
    return code
end

function generate_table_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    action_dispatch_code, set_act_code = generate_action_dispatch_code(ctx, machine, actions)
    trans_table = generate_transition_table(machine)
    getbyte_code = generate_geybyte_code(ctx)
    set_cs_code = :(@inbounds $(ctx.vars.cs) = $(trans_table)[($(ctx.vars.cs) - 1) << 8 + $(ctx.vars.byte) + 1])
    eof_action_code = generate_eof_action_code(ctx, machine, actions)
    final_state_code = generate_final_state_mem_code(ctx, machine)
    return quote
        $(ctx.vars.mem) = $(SizedMemory)($(ctx.vars.data))
        while $(ctx.vars.p) ≤ $(ctx.vars.p_end) && $(ctx.vars.cs) > 0
            $(getbyte_code)
            $(set_act_code)
            $(set_cs_code)
            $(action_dispatch_code)
            $(ctx.vars.p) += 1
        end
        if $(ctx.vars.p) > $(ctx.vars.p_eof) ≥ 0 && $(final_state_code)
            $(eof_action_code)
            $(ctx.vars.cs) = 0
        elseif $(ctx.vars.cs) < 0
            $(ctx.vars.p) -= 1
        end
    end
end

function generate_transition_table(machine::Machine)
    trans_table = Matrix{Int}(undef, 256, length(machine.states))
    for j in 1:size(trans_table, 2)
        trans_table[:,j] .= -j
    end
    for s in traverse(machine.start), (e, t) in s.edges
        if !isempty(e.precond)
            error("precondition is not supported in the table-based code generator; try code=:inline or :goto")
        end
        for l in e.labels
            trans_table[l+1,s.state] = t.state
        end
    end
    return trans_table
end

function generate_action_dispatch_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    action_table = fill(0, (256, length(machine.states)))
    action_ids = Dict{Vector{Symbol},Int}()
    for s in traverse(machine.start)
        for (e, t) in s.edges
            if isempty(e.actions)
                continue
            end
            id = get!(action_ids, action_names(e.actions), length(action_ids) + 1)
            for l in e.labels
                action_table[l+1,s.state] = id
            end
        end
    end
    act = gensym()
    default = :()
    action_dispatch_code = foldr(default, action_ids) do names_id, els
        names, id = names_id
        action_code = rewrite_special_macros(ctx, generate_action_code(names, actions), false)
        return Expr(:if, :($(act) == $(id)), action_code, els)
    end
    action_code = :(@inbounds $(act) = $(action_table)[($(ctx.vars.cs) - 1) << 8 + $(ctx.vars.byte) + 1])
    return action_dispatch_code, action_code
end

function generate_inline_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    trans_code = generate_transition_code(ctx, machine, actions)
    eof_action_code = generate_eof_action_code(ctx, machine, actions)
    getbyte_code = generate_geybyte_code(ctx)
    final_state_code = generate_final_state_mem_code(ctx, machine)
    return quote
        $(ctx.vars.mem) = $(SizedMemory)($(ctx.vars.data))
        while $(ctx.vars.p) ≤ $(ctx.vars.p_end) && $(ctx.vars.cs) > 0
            $(getbyte_code)
            $(trans_code)
            $(ctx.vars.p) += 1
        end
        if $(ctx.vars.p) > $(ctx.vars.p_eof) ≥ 0 && $(final_state_code)
            $(eof_action_code)
            $(ctx.vars.cs) = 0
        elseif $(ctx.vars.cs) < 0
            $(ctx.vars.p) -= 1
        end
    end
end

function generate_transition_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    default = :($(ctx.vars.cs) = -$(ctx.vars.cs))
    return foldr(default, traverse(machine.start)) do s, els
        then = foldr(default, optimize_edge_order(s.edges)) do edge, els′
            e, t = edge
            action_code = rewrite_special_macros(ctx, generate_action_code(e.actions, actions), false)
            then′ = :($(ctx.vars.cs) = $(t.state); $(action_code))
            return Expr(:if, generate_condition_code(ctx, e, actions), then′, els′)
        end
        return Expr(:if, state_condition(ctx, s.state), then, els)
    end
end

function generate_goto_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    actions_in = Dict{Node,Set{Vector{Symbol}}}()
    for s in traverse(machine.start), (e, t) in s.edges
        push!(get!(actions_in, t, Set{Vector{Symbol}}()), action_names(e.actions))
    end
    action_label = Dict{Node,Dict{Vector{Symbol},Symbol}}()
    for s in traverse(machine.start)
        action_label[s] = Dict()
        if haskey(actions_in, s)
            for (i, names) in enumerate(actions_in[s])
                action_label[s][names] = Symbol("state_", s.state, "_action_", i)
            end
        end
    end

    blocks = Expr[]
    for s in traverse(machine.start)
        block = Expr(:block)
        for (names, label) in action_label[s]
            if isempty(names)
                continue
            end
            append_code!(block, quote
                @label $(label)
                $(rewrite_special_macros(ctx, generate_action_code(names, actions), false, s.state))
                @goto $(Symbol("state_", s.state))
            end)
        end
        append_code!(block, quote
            @label $(Symbol("state_", s.state))
            $(ctx.vars.p) += 1
            if $(ctx.vars.p) > $(ctx.vars.p_end)
                $(ctx.vars.cs) = $(s.state)
                @goto exit
            end
        end)
        default = :($(ctx.vars.cs) = $(-s.state); @goto exit)
        dispatch_code = foldr(default, optimize_edge_order(s.edges)) do edge, els
            e, t = edge
            if isempty(e.actions)
                if ctx.loopunroll > 0 && s.state == t.state && length(e.labels) ≥ 4
                    then = generate_unrolled_loop(ctx, e, t)
                else
                    then = :(@goto $(Symbol("state_", t.state)))
                end
            else
                then = :(@goto $(action_label[t][action_names(e.actions)]))
            end
            return Expr(:if, generate_condition_code(ctx, e, actions), then, els)
        end
        append_code!(block, quote
            @label $(Symbol("state_case_", s.state))
            $(generate_geybyte_code(ctx))
            $(dispatch_code)
        end)
        push!(blocks, block)
    end

    enter_code = foldr(:(@goto exit), machine.states) do s, els
        return Expr(:if, :($(ctx.vars.cs) == $(s)), :(@goto $(Symbol("state_case_", s))), els)
    end

    eof_action_code = rewrite_special_macros(ctx, generate_eof_action_code(ctx, machine, actions), true)
    final_state_code = generate_final_state_mem_code(ctx, machine)

    return quote
        if $(ctx.vars.p) > $(ctx.vars.p_end)
            @goto exit
        end
        $(ctx.vars.mem) = $(SizedMemory)($(ctx.vars.data))
        $(enter_code)
        $(Expr(:block, blocks...))
        @label exit
        if $(ctx.vars.p) > $(ctx.vars.p_eof) ≥ 0 && $(final_state_code)
            $(eof_action_code)
            $(ctx.vars.cs) = 0
        end
    end
end

function generate_simd_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    ## SAME AS GOTO BEGIN
    actions_in = Dict{Node,Set{Vector{Symbol}}}()
    for s in traverse(machine.start), (e, t) in s.edges
        push!(get!(actions_in, t, Set{Vector{Symbol}}()), action_names(e.actions))
    end
    action_label = Dict{Node,Dict{Vector{Symbol},Symbol}}()
    for s in traverse(machine.start)
        action_label[s] = Dict()
        if haskey(actions_in, s)
            for (i, names) in enumerate(actions_in[s])
                action_label[s][names] = Symbol("state_", s.state, "_action_", i)
            end
        end
    end

    blocks = Expr[]
    for s in traverse(machine.start)
        block = Expr(:block)
        for (names, label) in action_label[s]
            if isempty(names)
                continue
            end
            append_code!(block, quote
                @label $(label)
                $(rewrite_special_macros(ctx, generate_action_code(names, actions), false, s.state))
                @goto $(Symbol("state_", s.state))
            end)
        end

        append_code!(block, quote
            @label $(Symbol("state_", s.state))
            $(ctx.vars.p) += 1
            if $(ctx.vars.p) > $(ctx.vars.p_end)
                $(ctx.vars.cs) = $(s.state)
                @goto exit
            end
        end)

        ### END SAME
        simd, non_simd = peel_simd_edge(s)
        simd_code = if simd !== nothing
            quote
                $(generate_simd_loop(ctx, simd.labels))
                if $(ctx.vars.p) > $(ctx.vars.p_end)
                    $(ctx.vars.cs) = $(s.state)
                    @goto exit
                end
            end
        else
            :()
        end
            
        default = :($(ctx.vars.cs) = $(-s.state); @goto exit)
        dispatch_code = foldr(default, optimize_edge_order(non_simd)) do edge, els
            e, t = edge
            if isempty(e.actions)
                then = :(@goto $(Symbol("state_", t.state)))
            else
                then = :(@goto $(action_label[t][action_names(e.actions)]))
            end
            return Expr(:if, generate_condition_code(ctx, e, actions), then, els)
        end
        # BEGIN SAME AGAIN
        append_code!(block, quote
            @label $(Symbol("state_case_", s.state))
            $(simd_code)
            $(generate_geybyte_code(ctx))
            $(dispatch_code)
        end)
        push!(blocks, block)
    end

    enter_code = foldr(:(@goto exit), machine.states) do s, els
        return Expr(:if, :($(ctx.vars.cs) == $(s)), :(@goto $(Symbol("state_case_", s))), els)
    end

    eof_action_code = rewrite_special_macros(ctx, generate_eof_action_code(ctx, machine, actions), true)
    final_state_code = generate_final_state_mem_code(ctx, machine)

    return quote
        if $(ctx.vars.p) > $(ctx.vars.p_end)
            @goto exit
        end
        $(ctx.vars.mem) = $(SizedMemory)($(ctx.vars.data))
        $(enter_code)
        $(Expr(:block, blocks...))
        @label exit
        if $(ctx.vars.p) > $(ctx.vars.p_eof) ≥ 0 && $(final_state_code)
            $(eof_action_code)
            $(ctx.vars.cs) = 0
        end
    end
end


function append_code!(block::Expr, code::Expr)
    @assert block.head == :block
    @assert code.head == :block
    append!(block.args, code.args)
    return block
end

function generate_unrolled_loop(ctx::CodeGenContext, edge::Edge, t::Node)
    # Generated code looks like this (when unroll=2):
    #     while p + 2 ≤ p_end
    #         l1 = $(getbyte)(data, p + 1)
    #         !$(generate_membership_code(:l1, e.labels)) && break
    #         l2 = $(getbyte)(data, p + 2)
    #         !$(generate_membership_code(:l2, e.labels)) && break
    #         p += 2
    #     end
    #     @goto ...
    @assert ctx.loopunroll > 0
    body = :(begin end)
    for k in 1:ctx.loopunroll
        l = Symbol(ctx.vars.byte, k)
        push!(
            body.args,
            quote
                $(generate_geybyte_code(ctx, l, k))
                $(generate_membership_code(l, edge.labels)) || begin
                    $(ctx.vars.p) += $(k-1)
                    break
                end
            end)
    end
    push!(body.args, :($(ctx.vars.p) += $(ctx.loopunroll)))
    quote
        while $(ctx.vars.p) + $(ctx.loopunroll) ≤ $(ctx.vars.p_end)
            $(body)
        end
        @goto $(Symbol("state_", t.state))
    end
end

# Note: This function has been carefully crafted to produce (nearly) optimal
# assembly code for AVX2-capable CPUs. Change with great care.
function generate_simd_loop(ctx::CodeGenContext, bs::ByteSet)
    byteset = ~ScanByte.ByteSet(bs)
    bsym = gensym()
    quote
        $bsym = Automa.loop_simd(
            $(ctx.vars.mem).ptr + $(ctx.vars.p) - 1,
            ($(ctx.vars.p_end) - $(ctx.vars.p) + 1) % UInt,
            Val($byteset)
        )
        $(ctx.vars.p) = if $bsym === nothing
            $(ctx.vars.p_end) + 1
        else
            $(ctx.vars.p) + $bsym - 1
        end
    end
end

@inline function loop_simd(ptr::Ptr, len::UInt, valbs::Val)
    ScanByte.memchr(ptr, len, valbs)
end

function generate_eof_action_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    return foldr(:(), machine.eof_actions) do s_as, els
        s, as = s_as
        action_code = rewrite_special_macros(ctx, generate_action_code(action_names(as), actions), true)
        Expr(:if, state_condition(ctx, s), action_code, els)
    end
end

function generate_action_code(list::ActionList, actions::Dict{Symbol,Expr})
    return generate_action_code(action_names(list), actions)
end

function generate_action_code(names::Vector{Symbol}, actions::Dict{Symbol,Expr})
    return Expr(:block, (actions[n] for n in names)...)
end

function generate_geybyte_code(ctx::CodeGenContext)
    return generate_geybyte_code(ctx, ctx.vars.byte, 0)
end

function generate_geybyte_code(ctx::CodeGenContext, varbyte::Symbol, offset::Int)
    code = :($(varbyte) = $(ctx.getbyte)($(ctx.vars.mem), $(ctx.vars.p) + $(offset)))
    if !ctx.checkbounds
        code = :(@inbounds $(code))
    end
    return code
end

function state_condition(ctx::CodeGenContext, s::Int)
    return :($(ctx.vars.cs) == $(s))
end

function generate_condition_code(ctx::CodeGenContext, edge::Edge, actions::Dict{Symbol,Expr})
    labelcode = generate_membership_code(ctx.vars.byte, edge.labels)
    precondcode = foldr(:(true), edge.precond) do p, ex
        name, value = p
        if value == BOTH
            ex1 = :(true)
        elseif value == TRUE
            ex1 = :( $(actions[name]))
        elseif value == FALSE
            ex1 = :(!$(actions[name]))
        else
            ex1 = :(false)
        end
        return Expr(:&&, ex1, ex)
    end
    return :($(labelcode) && $(precondcode))
end

# Check whether the final state belongs to `machine.final_states`.
# We simply unroll a bitvector and check for membership in that
function generate_final_state_mem_code(ctx::CodeGenContext, machine::Machine)
    # First create the bitvector, a dense vector of bits that are 1 for being
    # an accept state, and 0 for not. It's offset by `offset` bits.
    offset = minimum(machine.final_states)
    NBITS = 8*sizeof(UInt)
    len = length(offset:maximum(machine.final_states))
    uints = zeros(UInt, cld(len, NBITS))
    for state in machine.final_states
        arr_off, bit_off = divrem(state - offset, 8*sizeof(UInt))
        uints[arr_off + 1] = uints[arr_off + 1] | (1 << bit_off)
    end
    # For each uint in the vector, we check if CS in in the corresponding state
    ors = foldr(:(false), enumerate(uints)) do (i, u), oldx
        newx = quote
            (&)(
                $(ctx.vars.cs) < $(i * NBITS + offset),
                isodd($u >>> (($(ctx.vars.cs) - $offset) & $(NBITS-1)))
            )
        end
        Expr(:||, newx, oldx)
    end
    # Current state is at least minimum final state
    return Expr(:&&, :($(ctx.vars.cs) > $(offset - 1)), ors)
end

# Be careful trying to optimize this, LLVM creates insanely efficient code
# using this. Be sure to benchmark any improvements
function generate_membership_code(var::Symbol, set::ByteSet)
    min, max = minimum(set), maximum(set)
    @assert min isa UInt8 && max isa UInt8
    if max - min + 1 == length(set)
        # contiguous
        if min == max
            return :($(var) == $(min))
        else
            return :($(var) in $(min:max))
        end
    else
        return foldr((range, cond) -> Expr(:||, :($(var) in $(range)), cond),
                     :(false),
                     sort(range_encode(set), by=length, rev=true))
    end
end

# Used by the :table and :inline code generators.
function rewrite_special_macros(ctx::CodeGenContext, ex::Expr, eof::Bool)
    args = []
    for arg in ex.args
        if isescape(arg)
            if !eof
                push!(args, quote
                    $(ctx.vars.p) += 1
                    break
                end)
            end
        elseif isa(arg, Expr)
            push!(args, rewrite_special_macros(ctx, arg, eof))
        else
            push!(args, arg)
        end
    end
    return Expr(ex.head, args...)
end

# Used by the :goto code generator.
function rewrite_special_macros(ctx::CodeGenContext, ex::Expr, eof::Bool, cs::Int)
    args = []
    for arg in ex.args
        if isescape(arg)
            if !eof
                push!(args, quote
                    $(ctx.vars.cs) = $(cs)
                    $(ctx.vars.p) += 1
                    @goto exit
                end)
            end
        elseif isa(arg, Expr)
            push!(args, rewrite_special_macros(ctx, arg, eof, cs))
        else
            push!(args, arg)
        end
    end
    return Expr(ex.head, args...)
end

function isescape(arg)
    return arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@escape")
end

function cleanup(ex::Expr)
    args = []
    for arg in ex.args
        if isa(arg, Expr)
            if arg.head == :line
                # pass
            elseif ex.head == :block && arg.head == :block
                append!(args, cleanup(arg).args)
            else
                push!(args, cleanup(arg))
            end
        else
            push!(args, arg)
        end
    end
    return Expr(ex.head, args...)
end

function action_names(machine::Machine)
    actions = Set{Symbol}()
    for s in traverse(machine.start)
        for (e, t) in s.edges
            union!(actions, a.name for a in e.actions)
        end
    end
    for as in values(machine.eof_actions)
        union!(actions, a.name for a in as)
    end
    return actions
end

function debug_actions(machine::Machine)
    actions = action_names(machine)
    function log_expr(name)
        return :(push!(logger, $(QuoteNode(name))))
    end
    return Dict{Symbol,Expr}(name => log_expr(name) for name in actions)
end

"If possible, remove self-simd edge."
function peel_simd_edge(node)
    non_simd = Tuple{Edge, Node}[]
    simd = nothing
    for (e, t) in node.edges
        if t === node && isempty(e.actions) && isempty(e.precond)
            simd = e
        else
            push!(non_simd, (e, t))
        end
    end
    return simd, non_simd
end
    

# Sort edges by its size in descending order.
function optimize_edge_order(edges)
    return sort!(copy(edges), by=e->length(e[1].labels), rev=true)
end

# Generic foldr.
function foldr(op::Function, x0, xs)
    function rec(xs, s)
        if s === nothing
            return x0
        else
            return op(s[1], rec(xs, iterate(xs, s[2])))
        end
    end
    return rec(xs, iterate(xs))
end
