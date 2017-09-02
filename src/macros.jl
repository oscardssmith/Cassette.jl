############
# @context #
############

macro context(Ctx)
    @assert isa(Ctx, Symbol) "context name must be a Symbol"
    name = Expr(:quote, Ctx)
    return esc(quote
        struct $Ctx{T,M} <: $Cassette.Context{$name,T}
            tag::$Cassette.Tag{T}
            meta::M
        end
        @inline $Ctx(x, meta = nothing) = $Ctx($Cassette.Tag(x), meta)
        $Cassette.@hook $Ctx f(args...) = nothing
        $Cassette.@execution ctx::$Ctx f(args...) = $Cassette.lowercall(f, ctx, args...)
    end)
end

############
# @execute #
############

macro execute(ctx, call)
    @assert isa(call, Expr) && call.head == :call
    ctxsym = gensym("context")
    f = call.args[1]
    call.args[1] = :($Cassette.Intercept($ctxsym, $f))
    replace_match!(x -> :($Cassette.Meta($ctxsym, $(x.args[3:end]...))), ismetamacrocall, call.args)
    return esc(:($ctxsym = $ctx($f); $call))
end

#########
# @hook #
#########

macro hook(ctx, def)
    return contextual_transform!(ctx, :($Cassette._hook), def)
end

##############
# @execution #
##############

macro execution(ctx, def)
    return contextual_transform!(ctx, :($Cassette._execution), def)
end

################
# @isprimitive #
################

macro isprimitive(ctx, signature)
    body = Expr(:block)
    push!(body.args, :(return Val(true)))
    return contextual_transform!(ctx, :($Cassette._isprimitive), signature, body)
end

##############
# @primitive #
##############

macro primitive(ctx, def)
    @assert is_method_definition(def)
    signature = deepcopy(first(def.args))
    return esc(quote
        $Cassette.@execution $ctx $def
        $Cassette.@isprimitive $ctx $signature
    end)
end

#############
# utilities #
#############

macro Meta(args...)
    error("cannot use @Meta macro outside of the scope of Cassette's other macros (@execute, @execution, @isprimitive, @primitive, @hook)")
end

ismetamacrocall(x) = isa(x, Expr) && x.head == :macrocall && x.args[1] == Symbol("@Meta")

function contextual_transform!(ctx, f, method)
    @assert is_method_definition(method)
    signature, body = method.args
    return contextual_transform!(ctx, f, signature, body)
end

function contextual_transform!(ctx, f, signature::Expr, body::Expr)
    @assert is_valid_ctx_specification(ctx) "invalid context specifier: $ctx. Valid syntax is `ContextType` or `context_name::ContextType`."

    if signature.head != :where
        signature = Expr(:where, signature)
    end

    ctxtypevar = gensym("ContextTypeVar")
    if isa(ctx, Expr) && ctx.head == :(::)
        ctxtype = last(ctx.args)
        ctx.args[end] = ctxtypevar
    else
        ctxtype = ctx
        ctx = :(::$(ctxtypevar))
    end
    push!(signature.args, :($ctxtypevar <: $ctxtype))

    callargs = signature.args[1].args
    for i in 1:length(callargs)
        x = callargs[i]
        if isa(x, Expr) && x.head == :(::)
            xtype = last(x.args)
            if ismetamacrocall(xtype)
                metaargs = xtype.args[3:end]
                if isempty(metaargs)
                    U, M = :Any, :Any
                elseif length(metaargs) == 1
                    U, M = first(metaargs), :Any
                elseif length(metaargs) == 2
                    U, M = metaargs
                else
                    error("incorrect usage of `@Meta`: $(xtype)")
                end
                new_xtype = :($Cassette.Meta{$ctxtypevar,<:Any,<:$M,<:$U})
            else
                new_xtype = :(Union{$Cassette.Meta{<:Any,<:Any,<:Any,<:$xtype},$xtype})
            end
            x.args[end] = new_xtype
        end
    end

    signature.args[1] = Expr(:call, f, ctx, callargs...)

    unshift!(body.args, Expr(:meta, :inline))

    return esc(Expr(:function, signature, body))
end

function is_method_definition(x)
    if isa(x, Expr)
        if x.head == :function
            return true
        elseif x.head == :(=) && isa(x.args[1], Expr)
            lhs = x.args[1]
            if lhs.head == :where
                lhs = lhs.args[1]
            end
            return lhs.head == :call
        end
    end
    return false
end

function is_valid_ctx_specification(x)
    if isa(x, Expr)
        T = x.head == :(::) ? last(x.args) : x
        return is_valid_ctx_type(T)
    end
    return isa(x, Symbol)
end

is_valid_ctx_type(x::Symbol) = true
is_valid_ctx_type(x) = isa(x, Expr) && x.head == :(.) && is_valid_ctx_type(unquote(last(x.args)))

unquote(x) = x
unquote(x::QuoteNode) = x.value
unquote(x::Expr) = x.head == :quote ? first(x.args) : x

function unqualify_name(e::Expr)
    @assert e.head == :(.)
    return unqualify_name(last(e.args))
end

unqualify_name(name::Symbol) = name