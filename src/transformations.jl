export connect_system, rename_vars, remove_superfluous_states, substitute_algebraic_states, substitute_derivatives, set_p, simplify_eqs

"""
$(SIGNATURES)

Recursively transform `IOSystems` to `IOBlocks`.

- substitute inputs with connected outputs
- try to eliminate equations for internal states which are not used to calculate the specified outputs of the system.
- try to eliminate explicit algebraic equations (i.e. outputs of internal blocks) by substituting each occurrence
  with their rhs. Explicit algebraic states which are marked as system outputs won't be removed.

Arguments:
- `ios`: system to connect
- `verbose=false`: toggle verbosity (show equations at different steps)
- `remove_superflous_states=true`: toggle whether the system should try to get rid of unused states
- `substitute_algebraic_states=true`: toggle whether the algorithm tries to get rid of explicit algebraic equations
- `substitute_derivatives=true`: toggle whether to expand all derivatives and try to substitute them
- `simplify_eqs=true`: toggle simplification of all equations at the end
"""
function connect_system(ios::IOSystem;
                        verbose=false,
                        simplify_eqs=true,
                        remove_superflous_states=false,
                        substitute_algebraic_states=true,
                        substitute_derivatives=true,
                        warn=true)
    # recursive connect all subsystems
    for (i, subsys) in enumerate(ios.systems)
        if subsys isa IOSystem
            ios.systems[i] = connect_system(subsys, verbose=verbose)
        end
    end
    eqs = vcat([namespace_equations(iob.system) for iob in ios.systems]...)
    removed_eqs = vcat([namespace_rem_eqs(iob) for iob in ios.systems]...)

    verbose && @info "Transform IOSystem $(ios.name) to IOBlock" ios.name ios.inputs ios.outputs ios.connections eqs

    # get rid of closed inputs by substituting output states
    substitutions = reverse.(ios.connections)
    for (i, eq) in enumerate(eqs)
        eqs[i] = eq.lhs ~ substitute(eq.rhs, substitutions)
    end
    for (i, eq) in enumerate(removed_eqs)
        removed_eqs[i] = eq.lhs ~ substitute(eq.rhs, substitutions)
    end

    verbose && @info "substitute inputs with outputs" eqs

    # apply the namespace transformations
    promotion_rules = ios.namespace_map
    eqs = map(eq->eqsubstitute(eq, promotion_rules), eqs)
    removed_eqs  = map(eq->eqsubstitute(eq, promotion_rules), removed_eqs)

    block = IOBlock(ios.name, eqs, ios.inputs, ios.outputs, removed_eqs; iv=get_iv(ios), warn)

    if remove_superflous_states
        block = BlockSystems.remove_superflous_states(block; verbose, warn)
    end

    if substitute_algebraic_states
        block = BlockSystems.substitute_algebraic_states(block; verbose, warn)
    end

    if substitute_derivatives
        block = BlockSystems.substitute_derivatives(block; verbose, warn)
    end

    if simplify_eqs
        block = BlockSystems.simplify_eqs(block; warn)
    end

    return block
end


"""
    remove_superfluous_states(iob::IOBlock; verbose=false, warn=true)

This function removes equations from block, which are not used in order to
generate the outputs. It looks for equations which have no path to the outputs
equations in the dependency graph. Returns a new IOBlock.

The removed equations will be not available as removed equations of the new IOBlock

TODO: Maybe we should try to reduce the inputs to.
"""
function remove_superfluous_states(iob::IOBlock; verbose=false, warn=true)
    iv = get_iv(iob)
    outputs = iob.outputs

    neweqs = deepcopy(equations(iob))
    sys = ODESystem(neweqs, iv; name=:tmp) # will be used for the dependency graph
    neweqs = get_eqs(sys) # the ODESystem might reorder the equations
    # generate dependency graph
    graph = eqeq_dependencies(asgraph(sys), variable_dependencies(sys))
    # find 'main' eq for each output
    output_idx = [findfirst(x->o ∈ Set(get_variables(x.lhs)), neweqs) for o in outputs]

    if any(isnothing, output_idx)
        verbose && @info "Can't remove superfluous states if outputs implicitly defined."
        return neweqs
    end

    # if there is no path from equation to output equation is not necessary
    removable = []
    for eq_node in 1:length(neweqs)
        if !any(has_path(graph, eq_node, out_node) for out_node in output_idx)
            push!(removable, eq_node)
        end
    end

    removed_eqs = neweqs[removable]
    deleteat!(neweqs, sort(removable))

    verbose && @info "Removed superflous states with equations" removed_eqs

    IOBlock(iob.name, neweqs, iob.inputs, iob.outputs, iob.removed_eqs; iv, warn)
end


"""
    substitute_algebraic_states(iob::IOBlock; verbose=false, warn=true)

Reduces the number of equations by substituting explicit algebraic equations.
Returns a new IOBlock with the reduced equations. The removed eqs are stored
together with the previous `removed_eqs` in the new IOBlock.
Won't reduce algebraic states which are labeled as `output`.
"""
function substitute_algebraic_states(iob::IOBlock; verbose=false, warn=true)
    reduced_eqs = deepcopy(equations(iob))

    (rules, removable) = _algebraic_substitution_rules(reduced_eqs; skip=Set(iob.outputs))

    # subsitute all the equations, remove substituted
    for (i, eq) in enumerate(reduced_eqs)
        neweqs = eq.lhs ~ recursive_substitute(eq.rhs, rules)
        type, lhs_var = eq_type(neweqs)
        if type == :implicit_algebraic && !isnothing(lhs_var)
            verbose && print("Algebraic substitution resulted in implicit equation...")
            # TODO: solve_for implicit algebraic equations
            # try
            #     neweqs = lhs_var ~ Symbolics.solve_for(neweqs, lhs_var)
            #     verbose && println("which could be solved: $neweqs")
            # catch e
            #   e isa AssertionError || rethrow(e)
                neweqs = 0 ~ neweqs.rhs - neweqs.lhs
                verbose && println("which was transformed to `0 ~ f(...)` form: $neweqs")
            # end
        end
        reduced_eqs[i] = neweqs
    end

    # also substitute in the already removed_eqs
    removed_eqs = deepcopy(iob.removed_eqs)
    for (i, eq) in enumerate(removed_eqs)
        removed_eqs[i] = eq.lhs ~ recursive_substitute(eq.rhs, rules)
    end

    verbose && @info "Substituted algebraic states:" rules

    # append the knows removed wqs with the newly removed eqs
    append!(removed_eqs, reduced_eqs[removable])
    # remove removable equations from reduced_eqs
    deleteat!(reduced_eqs, sort(removable))

    IOBlock(iob.name, reduced_eqs, iob.inputs, iob.outputs, removed_eqs; iv=get_iv(iob), warn)
end

"""
    _algebraic_substitution_rules(eqs; skip=nothing)

Extract substitution rules for explicit algebraic equations in given equations.
Makes sure that those substitutions are pairwise cycle free.

Returns Tuple of substitution dict and corresponding indices of algebraic equations
in the given equations.
"""
function _algebraic_substitution_rules(eqs; skip=nothing)
    # only consider states for reduction which are explicit algebraic and not in outputs
    condition = eq -> begin
        (type, var) = eq_type(eq)
        type == :explicit_algebraic && (skip===nothing || var ∉ skip)
    end
    algebraic_idx = findall(condition, eqs)

    # symbols of all algebraic eqs
    symbols = [eq.lhs for eq ∈ eqs[algebraic_idx]]

    # generate dependency graph
    g = SimpleDiGraph(length(algebraic_idx))
    for (i, eq) in enumerate(eqs[algebraic_idx])
        rhs_vars = get_variables(eq.rhs)
        for (isym, sym) in enumerate(symbols)
            if Set([sym]) ⊆ Set(rhs_vars)
                add_edge!(g, isym => i)
            end
        end
    end
    removable = algebraic_idx[_pairwise_cycle_free(g)]
    @assert allunique(removable)

    rules = Dict(eq.lhs => eq.rhs for eq in eqs[removable])
    return (rules, removable)
end

"""
    _pairwise_cycle_free(g:SimpleDiGraph)

Returns an array of vertices, which pairwise do not belong to any cycle in `g`.
Uses `simplecycles` from `Graphs`. The algorithm starts with all vertices
and iteratively removes the vertices is part of most cycles.
"""
function _pairwise_cycle_free(g::SimpleDiGraph)
    idx = collect(vertices(g))
    cycles = simplecycles(g)
    while true
        cycles_per_idx = zeros(Int, length(idx))
        for (i, id1) ∈ enumerate(idx)
            for (j, id2) ∈ enumerate(@view idx[i+1 : end])
                for c in cycles
                    if id1 ∈ c && id2 ∈ c
                        cycles_per_idx[i] += 1
                        cycles_per_idx[i+j] += 1
                    end
                end
            end
        end
        if sum(cycles_per_idx) > 0
            worst_idx = findmax(cycles_per_idx)[2]
            deleteat!(idx, worst_idx)
        else
            return idx
        end
    end
end


"""
    substitute_derivatives(iob::IOBlock; verbose=false, warn=true)

Expand all derivatives in the RHS of the system. Try to substitute
in the lhs with their definition.

I.e.

    D(o) ~ 1 + D(i)   =>  D(o) ~ 2 + a
    D(i) ~ 1 + a          D(i) ~ 1 + a

Process happens in multiple steps:
- try to find explicit equation for differential
- if none found try to recursively substitute inside differential with known algebraic states
- expand derivatives and try again to substitute with known differentials

"""
function substitute_derivatives(iob::IOBlock; verbose=false, warn=true)
    diffs = rhs_differentials(iob)

    # if there are none just return the old block
    if isempty(diffs)
        verbose && @info "No rhs derivatives in block!"
        return iob
    end
    verbose && @info "Substitute rhs derivatives..."

    eqs = deepcopy(equations(iob))

    algebraic_subs = Dict{Symbolic, Any}()
    function lazy_alg_subs()
        if isempty(algebraic_subs)
            verbose && println("Lazily initialized algebraic substitutions for substitution of derivatives!")
            merge!(algebraic_subs, _algebraic_substitution_rules(eqs)[1])
        end
        return algebraic_subs
    end

    rules = Dict()
    known_differentials = Dict(eq.lhs => eq.rhs for eq in eqs if istree(eq.lhs) && operation(eq.lhs) isa Differential)
    for diff in diffs
        if haskey(known_differentials, diff)
            rules[diff] = known_differentials[diff]
            verbose && println("    ", diff, " => ", rules[diff])
        else
            substituted = recursive_substitute(diff, lazy_alg_subs())
            expanded = expand_derivatives(substituted)
            sub_known = substitute(expanded, known_differentials)

            rules[diff] = sub_known
            verbose && println("    ", diff, " => ", rules[diff])
            if verbose && !isempty(_collect_differentials(sub_known))
                println("        └ could not resolve this one!")
            end
        end
    end

    eqs = deepcopy(equations(iob))
    rem_eqs = deepcopy(iob.removed_eqs)

    for (i, eq) in enumerate(eqs)
        eqs[i] = eq.lhs ~ substitute(eq.rhs, rules)
    end
    for (i, eq) in enumerate(rem_eqs)
        rem_eqs[i] = eq.lhs ~ substitute(eq.rhs, rules)
    end

    newblock = IOBlock(iob.name, eqs, iob.inputs, iob.outputs, rem_eqs; iv=get_iv(iob), warn)

    return newblock
end


"""
    simplify_eqs(iob::IOBlock; verbose=false, warn=true)

Simplify eqs and removed eqs and return new IOBlock.
"""
function simplify_eqs(iob::IOBlock; verbose=false, warn=true)
    verbose && @info "Simplify iob equations..."
    simplified_eqs = simplify.(equations(iob))
    simplified_rem_eqs = simplify.(iob.removed_eqs)
    IOBlock(iob.name, simplified_eqs, iob.inputs, iob.outputs, simplified_rem_eqs; iv=get_iv(iob), warn)
end


"""
    rename_vars(blk::IOBLock; warn=true, kwargs...)
    rename_vars(blk::IOBlock, subs::Dict{Symbolic,Symbolic}; warn=true)

Returns new IOBlock which is similar to blk but with new variable names.
Variable renaming should be provided as keyword arguments, i.e.

    rename_vars(blk; x=:newx, k=:knew)

to rename `x(t)=>newx(t)` and `k=>knew`. Substitutions can be also provided as
dict of `Symbolic` types (`Sym`s and `Term`s).
"""
function rename_vars(blk::IOBlock; warn=true, kwargs...)
    substitutions = Dict{Symbolic, Symbolic}()
    for pair in kwargs
        key = remove_namespace(blk.name, getproperty(blk, pair.first))
        val = rename(key, pair.second)
        substitutions[key] = val
    end
    rename_vars(blk, substitutions; warn)
end

function rename_vars(blk::IOBlock, subs::Dict{Symbolic,Symbolic}; warn=true)
    eqs     = map(eq->eqsubstitute(eq, subs), get_eqs(blk.system))
    rem_eqs = map(eq->eqsubstitute(eq, subs), blk.removed_eqs)
    inputs  = map(x->substitute(x, subs), blk.inputs)
    outputs = map(x->substitute(x, subs), blk.outputs)
    IOBlock(blk.name, eqs, inputs, outputs, rem_eqs; iv=get_iv(blk), warn)
end


"""
    set_p(blk::IOBlock, p::Dict; warn=true)
    set_p(blk::IOBlock, p::Pair; warn=true)

Substitutes certain parameters by actual Float values. Returns an IOBlock without those parameters.

Keys of dict can be either `Symbols` or the `Symbolic` subtypes. I.e. `blk.u => 1.0` is as valid as `:u => 1.0`.
"""
function set_p(blk::IOBlock, p::Dict; warn=true)
    subs = Dict{Symbolic, Float64}()
    validp = Set(blk.iparams)
    for k in keys(p)
        if k isa Symbol
            sym = getproperty(blk, k)
        elseif k isa Num
            sym = value(k)
        elseif k isa Symbolic
            sym = k
        else
            error("Can't use $k, wrong type $(typeof(k))")
        end
        sym = remove_namespace(blk.name, sym)
        @check sym ∈ validp "Symbol $sym is not iparam of block"
        @check p[k] isa Number "p value has to be a number! Maybe you are looking for `rename_vars` instead?"
        subs[sym] = p[k]
    end
    eqs     = map(eq->eqsubstitute(eq, subs), equations(blk))
    rem_eqs = map(eq->eqsubstitute(eq, subs), blk.removed_eqs)
    IOBlock(blk.name, eqs, blk.inputs, blk.outputs, rem_eqs; iv=get_iv(blk), warn)
end

set_p(blk::IOBlock, p...; warn=true) = length(p) > 1 ? set_p(blk, Dict(p); warn) : set_p(blk, Dict(only(p)); warn)
